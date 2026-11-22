"""Synthetic archive/offload tests; never contact iCloud or touch real releases."""
import contextlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

import release_archive as archive


class FakeCloud:
    def __init__(self):
        self.dataless = False
        self.events = []
        self.on_download = None
        self.uploaded = True

    def status(self, path):
        return {"isUbiquitous": True, "isUploaded": self.uploaded, "isUploading": False,
                "dataless": self.dataless, "downloaded": not self.dataless, "hasConflicts": False}

    def evict(self, path):
        self.events.append("evict")
        self.dataless = True

    def download(self, path):
        self.events.append("download")
        self.dataless = False
        if self.on_download:
            action, self.on_download = self.on_download, None
            action(path)


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / "repo"
        self.folder = self.root / "build/testflight-7.1.1-100"
        self.folder.mkdir(parents=True)
        self.external = self.base / "external-signing"
        self.external.mkdir()
        (self.folder / "build").symlink_to(self.external)
        (self.folder / "verify").symlink_to(self.external / "verification")
        (self.external / "verification").mkdir()
        self.binary = self.external / "program"
        self.binary.write_bytes(b"synthetic symbols\x00" * 64)
        self.binary.chmod(0o751)
        os.utime(self.binary, ns=(1650000000123456789, 1650000000123456789))
        (self.external / "relative-link").symlink_to("program")
        (self.folder / "test.log").write_text("preserved test evidence\n")
        if sys.platform == "darwin":
            subprocess.run(["/usr/bin/xattr", "-w", "com.xdrip.archive.test", "metadata", str(self.binary)], check=True)
        self.state = {"tag": self.folder.name, "version": "7.1.1", "build": "100", "checkpoint": "a" * 40,
                      "step": "status-recorded", "appleStatus": "internal-testing",
                      "tests": {"verificationPassed": True}, "signingOutputRoot": str(self.external)}
        self.candidate = {"folder": self.folder, "state": self.state, "roots": [self.folder, self.external]}
        self.cloud_root = self.base / "cloud"
        self.config = {"icloudRoot": str(self.cloud_root), "waitSeconds": 0.001, "progress": False}
        self.cloud = FakeCloud()
        self.patches = contextlib.ExitStack()
        self.patches.enter_context(mock.patch.object(archive.guard, "ensure_unopened"))
        self.recheck = mock.Mock()

    def tearDown(self):
        self.patches.close()
        self.temporary.cleanup()

    def apply(self, before=None):
        return archive.archive_one(self.root, self.candidate, self.config, self.cloud, self.recheck, before)

    def test_cloud_roundtrip_restores_modes_symlinks_attributes_and_embedded_manifest(self):
        before = mock.Mock()
        tx = self.apply(before)
        self.assertEqual(tx["stage"], "offloaded")
        self.assertEqual(self.cloud.events[:3], ["evict", "download", "download"])
        before.assert_called_once()
        self.assertFalse(self.external.exists())
        self.assertEqual({p.name for p in self.folder.iterdir()}, {archive.STUB})
        receipt = archive.inspect_stub(self.folder)
        self.assertEqual(receipt["archiveSHA256"], archive.digest(Path(tx["archivePath"])))
        cat = archive.catalog_root(self.root) / self.folder.name
        manifest = archive.read_json(cat / "manifest.json")
        destination = self.base / "restored"
        roots = archive.extraction_check(Path(tx["archivePath"]), manifest, destination)
        self.assertEqual((Path(roots[str(self.external)]) / "program").stat().st_mode & 0o777, 0o751)
        self.assertEqual(os.readlink(Path(roots[str(self.folder)]) / "build"), str(self.external))
        self.assertTrue((destination / archive.EMBEDDED_MANIFEST).is_file())

    def test_pending_upload_retains_every_original(self):
        self.cloud.uploaded = False
        with self.assertRaisesRegex(archive.ArchiveBlocked, "pending"):
            self.apply()
        self.assertTrue(self.binary.exists())
        self.assertTrue((self.folder / "test.log").exists())
        tx = archive.read_json(archive.catalog_root(self.root) / self.folder.name / "transaction.json")
        self.assertEqual(tx["stage"], "upload-pending")
        self.cloud.uploaded = True
        self.assertEqual(self.apply()["stage"], "offloaded")

    def test_corrupt_cloud_download_never_removes_original(self):
        self.cloud.on_download = lambda path: Path(path).write_bytes(b"corrupt cloud response")
        with self.assertRaisesRegex(archive.ArchiveBlocked, "checksum"):
            self.apply()
        self.assertTrue(self.binary.is_file())
        self.assertTrue((self.folder / "test.log").is_file())

    def test_original_mutation_after_cloud_download_blocks_unlink(self):
        self.cloud.on_download = lambda _: self.binary.write_bytes(b"changed after packaging")
        with self.assertRaisesRegex(archive.ArchiveBlocked, "changed"):
            self.apply()
        self.assertEqual(self.binary.read_bytes(), b"changed after packaging")
        self.assertFalse((self.folder / archive.STUB).exists())

    def test_resume_after_packaged_rename_before_transaction_update(self):
        real = archive.create_package
        def crash(cat, manifest):
            real(cat, manifest)
            raise RuntimeError("synthetic crash after package rename")
        with mock.patch.object(archive, "create_package", side_effect=crash):
            with self.assertRaisesRegex(RuntimeError, "synthetic crash"):
                self.apply()
        self.assertTrue(self.binary.is_file())
        self.assertEqual(self.apply()["stage"], "offloaded")

    def test_resume_partial_original_removal(self):
        real = archive.unlink_manifest_item
        counter = [0]
        def crash(item, directories):
            counter[0] += 1
            result = real(item, directories)
            if counter[0] == 2:
                raise RuntimeError("synthetic crash during removal")
            return result
        with mock.patch.object(archive, "unlink_manifest_item", side_effect=crash):
            with self.assertRaisesRegex(RuntimeError, "synthetic crash"):
                self.apply()
        self.assertEqual(self.apply()["stage"], "offloaded")
        self.assertFalse(self.external.exists())

    def test_resume_after_stub_before_local_package_eviction(self):
        with mock.patch.object(archive, "finish_eviction", side_effect=RuntimeError("synthetic crash")):
            with self.assertRaisesRegex(RuntimeError, "synthetic crash"):
                self.apply()
        self.assertIsNotNone(archive.inspect_stub(self.folder))
        self.assertEqual(self.apply()["stage"], "offloaded")
        self.assertTrue(self.cloud.dataless)

    def test_stub_inspection_never_reads_cloud(self):
        tx = self.apply()
        Path(tx["archivePath"]).unlink()
        with mock.patch.object(archive.CloudBackend, "status", side_effect=AssertionError("cloud access")):
            self.assertEqual(archive.inspect_stub(self.folder)["build"], "100")

    def test_symlinked_stub_root_rejected_before_read(self):
        link = self.base / "testflight-7.1.1-101"
        link.symlink_to(self.cloud_root)
        with self.assertRaisesRegex(archive.ArchiveBlocked, "Symlinked"):
            archive.inspect_stub(link)

    def test_changed_receipt_and_unexpected_stub_file_rejected(self):
        self.apply()
        (self.folder / "unexpected").write_text("keep")
        with self.assertRaisesRegex(archive.ArchiveBlocked, "unexpected"):
            archive.inspect_stub(self.folder)

    def test_hardlinked_original_rejected(self):
        os.link(self.binary, self.external / "hardlink")
        with self.assertRaisesRegex(archive.ArchiveBlocked, "Hardlinked"):
            self.apply()
        self.assertTrue(self.binary.is_file())

    def test_git_checkout_inside_artifacts_rejected(self):
        (self.external / ".git").mkdir()
        with self.assertRaisesRegex(archive.ArchiveBlocked, "Git repository"):
            self.apply()
        self.assertTrue(self.binary.is_file())

    def test_parent_symlink_swap_never_unlinks_target(self):
        manifest = archive.make_manifest([self.external], self.state)
        item = next(f for f in manifest["files"] if f["path"] == str(self.binary))
        directories = {f["path"]: f for f in manifest["files"] if f["kind"] == "directory"}
        moved = self.base / "moved"
        self.external.rename(moved)
        self.external.symlink_to(moved)
        with self.assertRaises(OSError):
            archive.unlink_manifest_item(item, directories)
        self.assertTrue((moved / "program").is_file())

    def test_tar_traversal_rejected(self):
        package = self.base / "malicious.tar"
        with tarfile.open(package, "w") as output:
            member = tarfile.TarInfo("../escaped")
            output.addfile(member)
        manifest = archive.make_manifest([self.folder, self.external], self.state)
        with self.assertRaisesRegex(archive.ArchiveBlocked, "Unsafe archive"):
            archive.tar_check(package, manifest)

    def test_disabled_archive_does_not_compile_or_contact_cloud(self):
        with mock.patch.object(archive, "CloudBackend", side_effect=AssertionError("backend")):
            self.assertEqual(archive.archive(self.root, object(), apply=True)["status"], "disabled")

    def complete_release(self, number, version="7.1.1"):
        folder = self.root / ("build/testflight-%s-%s" % (version, number))
        folder.mkdir(exist_ok=True)
        out = self.external if folder == self.folder else folder / "build"
        (out / "export").mkdir(parents=True, exist_ok=True)
        ipa = out / "export/xdrip.ipa"
        ipa.write_bytes(b"synthetic IPA identity")
        (out / "archive/xdrip.xcarchive/dSYMs").mkdir(parents=True, exist_ok=True)
        (folder / "test/results/AllTests.xcresult").mkdir(parents=True, exist_ok=True)
        (folder / "apple-status.json").write_text("{}")
        state = dict(self.state, tag=folder.name, version=version, build=str(number),
                     ipaSha256=archive.digest(ipa), signingOutputRoot=str(out) if folder == self.folder else None)
        archive.save_json(folder / "release-state.json", state)
        return folder, state

    def test_selection_preserves_current_and_latest_previous_across_versions(self):
        self.complete_release(100)
        self.complete_release(101)
        previous, _ = self.complete_release(102, "8.0.0")
        current, state = self.complete_release(103, "8.1.0")
        with mock.patch.object(archive.guard, "command", return_value="a" * 40):
            candidates, kept, prior = archive.candidates(self.root, state)
        self.assertEqual(prior, 102)
        self.assertEqual({c["folder"].name for c in candidates}, {self.folder.name, "testflight-7.1.1-101"})
        self.assertIn(previous.name, {c["release"] for c in kept})
        self.assertIn(current.name, {c["release"] for c in kept})

    def test_overlap_with_incomplete_release_external_output_blocks(self):
        self.complete_release(100)
        self.complete_release(102)
        _, current = self.complete_release(103)
        unknown = self.root / "build/testflight-7.1.1-101"
        unknown.mkdir()
        (unknown / "build").symlink_to(self.external)
        with mock.patch.object(archive.guard, "command", return_value="a" * 40):
            with self.assertRaisesRegex(archive.ArchiveBlocked, "overlaps another release"):
                archive.candidates(self.root, current)

    def test_offloaded_candidate_skips_cloud_in_future_runs(self):
        self.apply()
        self.complete_release(102)
        _, current = self.complete_release(103)
        with mock.patch.object(archive.guard, "command", return_value="a" * 40):
            candidates, kept, _ = archive.candidates(self.root, current)
        self.assertEqual(candidates, [])
        self.assertIn(self.folder.name, {c["release"] for c in kept})

    def test_missing_cloud_copy_after_stub_keeps_last_local_package(self):
        with mock.patch.object(archive, "finish_eviction", side_effect=RuntimeError("crash")):
            with self.assertRaisesRegex(RuntimeError, "crash"):
                self.apply()
        cat = archive.catalog_root(self.root) / self.folder.name
        tx = archive.read_json(cat / "transaction.json")
        Path(tx["archivePath"]).unlink()
        with self.assertRaises(FileNotFoundError):
            self.apply()
        self.assertTrue((cat / "package.tar.gz").is_file())

    def test_apple_recheck_failure_before_removal_retains_originals(self):
        def blocked():
            raise RuntimeError("Apple state changed")
        with self.assertRaisesRegex(RuntimeError, "Apple state changed"):
            self.apply(blocked)
        self.assertTrue(self.binary.exists())
        self.assertTrue((self.folder / "test.log").exists())
        tx = archive.read_json(archive.catalog_root(self.root) / self.folder.name / "transaction.json")
        self.assertEqual(tx["stage"], "cloud-roundtrip-verified")

    def test_restore_api_new_destination_and_dry_run_no_cloud(self):
        self.apply()
        destination = self.base / "requested-restore"
        with mock.patch.object(archive, "CloudBackend", side_effect=AssertionError("cloud")):
            result = archive.restore_archive(self.root, self.folder.name, destination, apply=False)
        self.assertEqual(result["status"], "dry-run")
        self.assertFalse(destination.exists())
        with mock.patch.object(archive, "load_config", return_value=self.config), \
                mock.patch.object(archive.guard, "idle"), \
                mock.patch.object(archive.guard, "git_snapshot", return_value={}), \
                mock.patch.object(archive, "build_lock", side_effect=contextlib.nullcontext):
            result = archive.restore_archive(self.root, self.folder.name, destination, apply=True, cloud=self.cloud)
        self.assertEqual(result["status"], "restored-and-verified")
        self.assertTrue((destination / "RESTORE-MAP.json").exists())
        with self.assertRaisesRegex(archive.ArchiveBlocked, "must not exist"):
            archive.restore_archive(self.root, self.folder.name, destination, apply=True, cloud=self.cloud)

    def test_git_object_alternates_repository_is_protected(self):
        common = self.root / ".git"
        (common / "objects/info").mkdir(parents=True)
        recovery = self.base / "recovery"
        (recovery / "objects/info").mkdir(parents=True)
        (common / "objects/info/alternates").write_text(str(recovery / "objects") + "\n")
        with mock.patch.object(archive.guard, "command", return_value=".git"):
            protected = archive.protected_git_roots(self.root, {str(self.root): {}, "refs": ""})
        self.assertIn(recovery, protected)

    def test_archive_obeys_shared_lock_before_apple_or_file_access(self):
        with mock.patch.object(archive, "load_config", return_value=self.config), \
                mock.patch.object(archive, "build_lock", side_effect=RuntimeError("Another build holds lock")), \
                mock.patch.object(archive.guard, "confirm_apple") as apple:
            with self.assertRaisesRegex(RuntimeError, "holds lock"):
                archive.archive(self.root, object(), apply=True, cloud=self.cloud)
        apple.assert_not_called()
        self.assertTrue(self.binary.exists())

    def test_atomic_catalog_write_does_not_truncate_old_temp_hardlink(self):
        cat = self.base / "catalog"
        cat.mkdir()
        victim = self.base / "victim"
        victim.write_text("keep")
        os.link(victim, cat / "record.json.tmp")
        archive.save_json(cat / "record.json", {"safe": True})
        self.assertEqual(victim.read_text(), "keep")

    def test_complete_interrupted_restore_verification_resumes_same_tree(self):
        with mock.patch.object(archive, "remove_verification", side_effect=RuntimeError("crash after verification")):
            with self.assertRaisesRegex(RuntimeError, "crash after verification"):
                self.apply()
        cat = archive.catalog_root(self.root) / self.folder.name
        self.assertTrue((cat / "restore-check").is_dir())
        self.assertEqual(self.apply()["stage"], "offloaded")
        self.assertFalse((cat / "restore-check").exists())


if __name__ == "__main__":
    unittest.main()
