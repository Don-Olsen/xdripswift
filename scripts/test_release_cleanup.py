#!/usr/bin/env python3
"""Offline safety tests. All removals are confined to fresh synthetic temp trees."""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile
from unittest import mock

import release_cleanup as c
import build_lock as locks
import local_run_receipt as receipts

class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")
        self.git("config", "core.hooksPath", "/dev/null")
        (self.root / ".gitignore").write_text("build/\n")
        (self.root / "source.swift").write_text("source")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.head = self.git("rev-parse", "HEAD").strip()
        self.old = self.make_release("99")
        self.previous = self.make_release("100")
        self.current = self.make_release("101")
        self.write(self.root / "build/release-automation/active.json", {"version":"7.1.1", "build":"101"})
        # Keep storage inventory in the synthetic fixture, not the host's build area.
        self.patches = [mock.patch.object(c.Path, "home", return_value=self.root / "synthetic-home"),
                        mock.patch.object(c, "idle"), mock.patch.object(c, "ensure_unopened"),
                        mock.patch.object(c, "build_lock", contextlib.nullcontext)]
        for patch in self.patches:
            patch.start(); self.addCleanup(patch.stop)
        self.client = mock.Mock()
        row = {"version":"7.1.1", "build":"101", "id":"id-101", "processingState":"VALID",
               "betaInternalState":"IN_BETA_TESTING", "buildAudienceType":"INTERNAL_ONLY", "expired":False}
        self.client.snapshot.return_value = {"observedAt":"fixture", "appID":"6795645396", "bundleID":"com.GFZ896KN66.xdripswift", "platform":"IOS", "version":"7.1.1", "builds":[row], "uploads":[]}
        self.client._pages.return_value = [{"data":[{"id":"group", "attributes":{"name":"Ole Internal","isInternalGroup":True}}]}]
        self.client._group_build_ids.return_value = {"id-101"}

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True, stderr=subprocess.DEVNULL)

    def write(self, p, data):
        p.parent.mkdir(parents=True, exist_ok=True); p.write_text(json.dumps(data))

    def make_release(self, number):
        r = self.root / ("build/testflight-7.1.1-" + number)
        ipa = r / "build/export/xdrip.ipa"; ipa.parent.mkdir(parents=True); ipa.write_bytes(b"IPA")
        (r / "build/archive/xdrip.xcarchive/dSYMs").mkdir(parents=True)
        (r / "test/results/AllTests.xcresult").mkdir(parents=True)
        (r / "apple-status.json").write_text("{}")
        tag = "testflight-7.1.1-" + number; self.git("tag", tag)
        state = {"version":"7.1.1", "build":number, "step":"status-recorded", "appleStatus":"internal-testing",
                 "tests":{"verificationPassed":True}, "tag":tag, "checkpoint":self.head,
                 "ipaSha256":c.hash_file(ipa), "appleObservation":{"buildRecord":{"id":"id-"+number}}}
        self.write(r / "release-state.json", state)
        dd = r / "test/DerivedData/all-tests"
        for name in ("ModuleCache.noindex/test.pcm", "Index.noindex/DataStore/records/index-record",
                     "Build/Intermediates.noindex/temp.o", "Build/Intermediates.noindex/map.json",
                     "Build/Intermediates.noindex/generated.swift", "Build/Products/app.dSYM/symbol",
                     "Build/Products/app.app/binary", "Logs/Build/a.xcactivitylog", "TestResults/runtime.json",
                     "CompilationCache.noindex/debug.log", "ModuleCache.noindex/unknown.txt"):
            p=dd/name; p.parent.mkdir(parents=True,exist_ok=True); p.write_bytes(b"preserve or cache"*100)
        return r

    def cache(self, r=None):
        return (r or self.old) / "test/DerivedData/all-tests/ModuleCache.noindex/test.pcm"

    def manifest(self, r):
        return {str(p.relative_to(r)):p.read_bytes() for p in r.rglob("*") if p.is_file()}

    def external_signing(self, release=None):
        release = release or self.old
        temporary = tempfile.TemporaryDirectory(dir=self.root.parent)
        self.addCleanup(temporary.cleanup)
        external = Path(temporary.name) / "signing"
        (release / "build").rename(external)
        (release / "build").symlink_to(external, target_is_directory=True)
        (external / "verification").mkdir()
        (release / "verify").symlink_to(external / "verification", target_is_directory=True)
        state_path = release / "release-state.json"
        state = json.loads(state_path.read_text())
        state["signingOutputRoot"] = str(external)
        self.write(state_path, state)
        return external

    def test_apply_removes_only_cache_and_preserves_current_and_evidence(self):
        current=self.manifest(self.current); before=self.manifest(self.old)
        result=c.cleanup(self.root,self.client,True)
        self.assertEqual(result["deletedFiles"],4)
        self.assertFalse(self.cache().exists())
        self.assertEqual(self.manifest(self.current),current)
        after=self.manifest(self.old)
        removed=set(before)-set(after)
        self.assertTrue(all(c.disposable(Path(n).relative_to("test/DerivedData/all-tests"))
                            or n.endswith("Build/Products/app.app/binary") for n in removed))
        self.assertTrue(all(before[n]==v for n,v in after.items()))
        self.assertEqual(result["gitBefore"],result["gitAfter"])
        self.assertEqual(self.git("rev-parse","HEAD").strip(),self.head)

    def test_latest_previous_verified_build_is_complete_and_untouched(self):
        before = self.manifest(self.previous)
        result = c.cleanup(self.root, self.client, True)
        self.assertEqual(self.manifest(self.previous), before)
        self.assertTrue(any(item["path"] == str(self.previous)
                            and item["reason"] == "latest previous verified build"
                            for item in result["kept"]))

    def test_exact_ipa_extractions_are_reclaimed_but_ipa_and_archive_remain(self):
        ipa = self.old / "build/export/xdrip.ipa"
        with zipfile.ZipFile(ipa, "w") as package:
            package.writestr("Payload/xdrip.app/xdrip", b"signed binary")
            package.writestr("Payload/xdrip.app/Info.plist", b"signed plist")
        state_path = self.old / "release-state.json"
        state = json.loads(state_path.read_text())
        state["ipaSha256"] = c.hash_file(ipa)
        self.write(state_path, state)
        for root in (self.old / "build/export-verification", self.old / "verify/ipa-fixture"):
            (root / "Payload/xdrip.app").mkdir(parents=True)
            (root / "Payload/xdrip.app/xdrip").write_bytes(b"signed binary")
            (root / "Payload/xdrip.app/Info.plist").write_bytes(b"signed plist")
        result = c.cleanup(self.root, self.client, True)
        self.assertEqual(result["deletedFiles"], 8)
        self.assertTrue(ipa.is_file())
        self.assertTrue((self.old / "build/archive/xdrip.xcarchive/dSYMs").is_dir())
        self.assertFalse((self.old / "verify/ipa-fixture/Payload/xdrip.app/xdrip").exists())
        self.assertEqual(c.cleanup(self.root, self.client, True)["deletedFiles"], 0)
        self.assertTrue(all("reason" in json.loads(line) for line in
                            (Path(result["reportPath"]).parent / "deleted.jsonl").read_text().splitlines()))

    def test_approved_external_verify_link_reclaims_cache_and_exact_ipa_copy(self):
        external = self.external_signing()
        ipa = self.old / "build/export/xdrip.ipa"
        with zipfile.ZipFile(ipa, "w") as package:
            package.writestr("Payload/xdrip.app/xdrip", b"signed binary")
        state_path = self.old / "release-state.json"
        state = json.loads(state_path.read_text())
        state["ipaSha256"] = c.hash_file(ipa)
        self.write(state_path, state)
        copy = external / "verification/ipa-fixture/Payload/xdrip.app/xdrip"
        copy.parent.mkdir(parents=True)
        copy.write_bytes(b"signed binary")
        previous = self.manifest(self.previous)
        current = self.manifest(self.current)
        dry = c.cleanup(self.root, self.client)
        self.assertEqual(dry["status"], "dry-run")
        self.assertTrue(self.cache().exists())
        self.assertTrue(copy.exists())
        self.assertTrue(any(row["build"] == "99" for row in dry["candidates"]))
        result = c.cleanup(self.root, self.client, True)
        self.assertEqual(result["deletedFiles"], 5)
        self.assertFalse(self.cache().exists())
        self.assertFalse(copy.exists())
        self.assertTrue((self.old / "verify").is_symlink())
        self.assertTrue(ipa.is_file())
        self.assertTrue((self.old / "build/archive/xdrip.xcarchive/dSYMs").is_dir())
        self.assertTrue((self.old / "test/results/AllTests.xcresult").is_dir())
        self.assertEqual(self.manifest(self.previous), previous)
        self.assertEqual(self.manifest(self.current), current)
        self.assertEqual(result["gitBefore"], result["gitAfter"])
        self.assertEqual(c.cleanup(self.root, self.client, True)["deletedFiles"], 0)

    def test_external_verify_link_rejects_other_target_and_extra_redirect(self):
        external = self.external_signing()
        verify = self.old / "verify"
        other = external.parent / "other-verification"
        other.mkdir()
        redirect = external.parent / "redirect"
        redirect.symlink_to(external / "verification", target_is_directory=True)
        for target in (other, redirect):
            verify.unlink()
            verify.symlink_to(target, target_is_directory=True)
            result = c.cleanup(self.root, self.client, True)
            self.assertEqual(result["deletedFiles"], 0)
            self.assertTrue(self.cache().exists())
            self.assertTrue(any(row["path"] == str(self.old)
                                and row["reason"] == "Unknown verify root" for row in result["kept"]))

    def test_external_verify_link_rejects_redirected_or_missing_target_directory(self):
        external = self.external_signing()
        verification = external / "verification"
        verification.rmdir()
        other = external.parent / "other-verification"
        other.mkdir()
        verification.symlink_to(other, target_is_directory=True)
        self.assertEqual(c.cleanup(self.root, self.client, True)["deletedFiles"], 0)
        self.assertTrue(self.cache().exists())
        verification.unlink()
        with self.assertRaisesRegex(c.CleanupBlocked, "Broken release output link"):
            c.cleanup(self.root, self.client, True)
        self.assertTrue(self.cache().exists())

    def test_verify_link_without_approved_external_build_is_rejected(self):
        verification = self.old / "build/verification"
        verification.mkdir()
        (self.old / "verify").symlink_to(verification, target_is_directory=True)
        result = c.cleanup(self.root, self.client, True)
        self.assertEqual(result["deletedFiles"], 0)
        self.assertTrue(self.cache().exists())
        self.assertTrue(any(row["path"] == str(self.old)
                            and row["reason"] == "Unknown verify root" for row in result["kept"]))

    def test_external_verify_link_does_not_enter_current_build(self):
        external = self.external_signing(self.current)
        old_build = self.old / "build"
        old_build.rename(self.old / "preserved-output")
        old_build.symlink_to(external, target_is_directory=True)
        verify = self.old / "verify"
        verify.symlink_to(external / "verification", target_is_directory=True)
        state_path = self.old / "release-state.json"
        state = json.loads(state_path.read_text())
        state["signingOutputRoot"] = str(external)
        self.write(state_path, state)
        result = c.cleanup(self.root, self.client, True)
        self.assertEqual(result["deletedFiles"], 0)
        self.assertTrue(self.cache().exists())
        self.assertTrue(any(row["path"] == str(self.old)
                            and row["reason"] == "Verify root overlaps protected build"
                            for row in result["kept"]))

    def test_external_verify_link_keeps_release_on_ipa_copy_mismatch(self):
        external = self.external_signing()
        ipa = self.old / "build/export/xdrip.ipa"
        with zipfile.ZipFile(ipa, "w") as package:
            package.writestr("Payload/xdrip.app/xdrip", b"original")
        state_path = self.old / "release-state.json"
        state = json.loads(state_path.read_text())
        state["ipaSha256"] = c.hash_file(ipa)
        self.write(state_path, state)
        copy = external / "verification/ipa-fixture/Payload/xdrip.app/xdrip"
        copy.parent.mkdir(parents=True)
        copy.write_bytes(b"different")
        result = c.cleanup(self.root, self.client, True)
        self.assertEqual(result["deletedFiles"], 0)
        self.assertTrue(self.cache().exists())
        self.assertEqual(copy.read_bytes(), b"different")

    def test_external_signing_link_cannot_target_repo_or_ancestor(self):
        out = self.old / "build"
        out.rename(self.old / "preserved-output")
        state_path = self.old / "release-state.json"
        state = json.loads(state_path.read_text())
        for target in (self.root, self.root.parent):
            out.symlink_to(target, target_is_directory=True)
            state["signingOutputRoot"] = str(target)
            self.write(state_path, state)
            candidates, kept = c.release_candidates(
                self.root, json.loads((self.current / "release-state.json").read_text()))
            self.assertFalse(any(row["build"] == "99" for row in candidates))
            self.assertTrue(self.cache().exists())
            self.assertTrue(any(row["path"] == str(self.old)
                                and row["reason"] == "Unknown external signing output"
                                for row in kept))
            out.unlink()

    def test_external_release_link_change_after_planning_blocks_first_unlink(self):
        external = self.external_signing()
        verify = self.old / "verify"
        other = external.parent / "other-verification"
        other.mkdir()
        original = c.preservation_inventory
        changed = False
        def retarget_after_inventory(*args, **kwargs):
            nonlocal changed
            value = original(*args, **kwargs)
            if not changed:
                verify.unlink()
                verify.symlink_to(other, target_is_directory=True)
                changed = True
            return value
        with mock.patch.object(c, "preservation_inventory", side_effect=retarget_after_inventory):
            with self.assertRaisesRegex(c.CleanupBlocked, "Release link changed"):
                c.cleanup(self.root, self.client, True)
        self.assertTrue(self.cache().exists())

    def test_external_release_link_change_during_apply_stops_next_unlink(self):
        external = self.external_signing()
        build_link = self.old / "build"
        other = external.parent / "other-signing"
        other.mkdir()
        paths = [self.old / "test/DerivedData/all-tests" / relative for relative in (
            "ModuleCache.noindex/test.pcm", "Index.noindex/DataStore/records/index-record",
            "Build/Intermediates.noindex/temp.o", "Build/Products/app.app/binary")]
        original = c.safe_unlink
        changed = False
        def retarget_after_first_unlink(item):
            nonlocal changed
            original(item)
            if not changed:
                build_link.unlink()
                build_link.symlink_to(other, target_is_directory=True)
                changed = True
        with mock.patch.object(c, "safe_unlink", side_effect=retarget_after_first_unlink):
            with self.assertRaisesRegex(c.CleanupBlocked, "Release link changed"):
                c.cleanup(self.root, self.client, True)
        self.assertEqual(sum(not path.exists() for path in paths), 1)
        reports = sorted((self.root / "build/release-automation/cleanup").glob("*/report.json"))
        self.assertTrue(reports)
        report = json.loads(reports[-1].read_text())
        self.assertEqual(report["status"], "stopped")
        self.assertEqual(report["deletedFiles"], 1)

    def test_mismatched_ipa_copy_preserves_entire_old_release(self):
        ipa = self.old / "build/export/xdrip.ipa"
        with zipfile.ZipFile(ipa, "w") as package:
            package.writestr("Payload/xdrip.app/xdrip", b"original")
        state_path = self.old / "release-state.json"
        state = json.loads(state_path.read_text()); state["ipaSha256"] = c.hash_file(ipa)
        self.write(state_path, state)
        copy = self.old / "build/export-verification/Payload/xdrip.app/xdrip"
        copy.parent.mkdir(parents=True); copy.write_bytes(b"different")
        result = c.cleanup(self.root, self.client, True)
        self.assertEqual(result["deletedFiles"], 0)
        self.assertTrue(copy.exists())
        self.assertTrue(self.cache().exists())

    def test_finder_metadata_does_not_block_or_get_deleted(self):
        finder = self.old / "test/DerivedData/.DS_Store"
        finder.write_bytes(b"finder")
        nested = self.old / "test/DerivedData/all-tests/.DS_Store"
        nested.write_bytes(b"finder")
        result = c.cleanup(self.root, self.client, True)
        self.assertEqual(result["deletedFiles"], 4)
        self.assertEqual(finder.read_bytes(), b"finder")
        self.assertEqual(nested.read_bytes(), b"finder")

    def test_dry_run_never_removes(self):
        before=self.manifest(self.old)
        self.assertEqual(c.cleanup(self.root,self.client)["status"],"dry-run")
        self.assertEqual(self.manifest(self.old),before)

    def test_second_apply_is_idempotent(self):
        c.cleanup(self.root,self.client,True)
        self.assertEqual(c.cleanup(self.root,self.client,True)["deletedFiles"],0)

    def test_space_limit_reports_protected_residue_without_extra_deletion(self):
        current = self.manifest(self.current)
        with mock.patch.object(c, "BUILD_AREA_LIMIT_BYTES", 1):
            result = c.cleanup(self.root, self.client, True)
        self.assertGreater(result["buildAreaAfter"]["overLimitBytes"], 0)
        self.assertIn("limit-unmet", result["spaceLimitResult"])
        self.assertEqual(self.manifest(self.current), current)
        self.assertEqual(result["deletedFiles"], 4)

    def test_product_link_blocks_that_release_without_following_it(self):
        link = self.old / "test/DerivedData/all-tests/Build/Products/app.app/external"
        link.symlink_to(self.root / "source.swift")
        result = c.cleanup(self.root, self.client, True)
        self.assertEqual(result["deletedFiles"], 0)
        self.assertTrue(self.cache().exists())
        self.assertEqual((self.root / "source.swift").read_text(), "source")

    def test_busy_before_planning_removes_nothing(self):
        with mock.patch.object(c,"idle",side_effect=c.CleanupBlocked("Xcode")):
            with self.assertRaises(c.CleanupBlocked): c.cleanup(self.root,self.client,True)
        self.assertTrue(self.cache().exists()); self.client.snapshot.assert_not_called()

    def test_busy_after_planning_removes_nothing(self):
        with mock.patch.object(c,"idle",side_effect=[None,c.CleanupBlocked("upload")]):
            with self.assertRaises(c.CleanupBlocked): c.cleanup(self.root,self.client,True)
        self.assertTrue(self.cache().exists())

    def test_api_failure_removes_nothing(self):
        self.client.snapshot.side_effect=RuntimeError("offline")
        with self.assertRaises(RuntimeError): c.cleanup(self.root,self.client,True)
        self.assertTrue(self.cache().exists())

    def test_newer_apple_upload_blocks_everything(self):
        self.client.snapshot.return_value["uploads"]=[{"build":"102"}]
        with self.assertRaises(c.CleanupBlocked): c.cleanup(self.root,self.client,True)
        self.assertTrue(self.cache().exists())

    def test_non_testing_and_missing_group_block(self):
        for field,value in (("processingState","PROCESSING"),("expired",True),("buildAudienceType","APP_STORE")):
            row=self.client.snapshot.return_value["builds"][0]; old=row[field]; row[field]=value
            with self.assertRaises(c.CleanupBlocked): c.cleanup(self.root,self.client,True)
            row[field]=old
        self.client._group_build_ids.return_value=set()
        with self.assertRaises(c.CleanupBlocked): c.cleanup(self.root,self.client,True)
        self.assertTrue(self.cache().exists())

    def test_open_files_block(self):
        with mock.patch.object(c,"ensure_unopened",side_effect=c.CleanupBlocked("open")):
            with self.assertRaises(c.CleanupBlocked): c.cleanup(self.root,self.client,True)
        self.assertTrue(self.cache().exists())

    def test_incomplete_old_release_preserved(self):
        p=self.old/'release-state.json'; s=json.loads(p.read_text());s['step']='tagged';self.write(p,s)
        self.assertEqual(c.cleanup(self.root,self.client,True)['deletedFiles'],0)
        self.assertTrue(self.cache().exists())

    def test_missing_ipa_archive_result_or_bad_hash_preserved(self):
        for path in ('build/export/xdrip.ipa','test/results/AllTests.xcresult','build/archive/xdrip.xcarchive/dSYMs'):
            p=self.old/path; backup=p.with_name(p.name+'.hold');p.rename(backup)
            self.assertEqual(c.cleanup(self.root,self.client,True)['deletedFiles'],0)
            backup.rename(p)
        (self.old/'build/export/xdrip.ipa').write_bytes(b'changed')
        self.assertEqual(c.cleanup(self.root,self.client,True)['deletedFiles'],0)

    def test_symlink_cache_and_hardlink_preserved(self):
        p=self.cache();p.unlink();p.symlink_to(self.root/'source.swift')
        self.assertEqual(c.cleanup(self.root,self.client,True)['deletedFiles'],0)
        p.unlink();os.link(self.root/'source.swift',p)
        self.assertEqual(c.cleanup(self.root,self.client,True)['deletedFiles'],0)
        self.assertEqual((self.root/'source.swift').read_text(),'source')

    def test_product_symlinks_preserved_without_following(self):
        p=self.old/'test/DerivedData/all-tests/Build/Intermediates.noindex/BuildProductsPath'
        p.symlink_to(self.current,target_is_directory=True)
        current=self.manifest(self.current)
        self.assertEqual(c.cleanup(self.root,self.client,True)['deletedFiles'],4)
        self.assertTrue(p.is_symlink());self.assertEqual(self.manifest(self.current),current)

    def test_current_newer_and_unrecognized_local_builds_preserved(self):
        newer=self.make_release('102');before=self.manifest(newer)
        unknown=self.root/'build/local/setup/DerivedData/a/ModuleCache.noindex/test.pcm'
        unknown.parent.mkdir(parents=True);unknown.write_text('unknown')
        c.cleanup(self.root,self.client,True)
        self.assertEqual(self.manifest(newer),before);self.assertEqual(unknown.read_text(),'unknown')

    def test_current_overlap_through_external_link_is_rejected(self):
        out=self.old/'build';out.rename(self.old/'preserved-output')
        out.symlink_to(self.current/'build',target_is_directory=True)
        p=self.old/'release-state.json';s=json.loads(p.read_text());s['signingOutputRoot']=str(self.current/'build');self.write(p,s)
        self.assertEqual(c.cleanup(self.root,self.client,True)['deletedFiles'],0)

    def test_tracked_cache_file_blocks(self):
        self.git('add','-f',str(self.cache()))
        with self.assertRaises(c.CleanupBlocked):c.cleanup(self.root,self.client,True)
        self.assertTrue(self.cache().exists())

    def test_safe_unlink_rejects_changed_file(self):
        p=self.cache();item={'path':str(p),'fingerprint':c.fingerprint(p)};p.write_text('changed')
        with self.assertRaises(c.CleanupBlocked):c.safe_unlink(item)
        self.assertTrue(p.exists())

    def test_safe_unlink_allows_metadata_only_ctime_change(self):
        p = self.cache()
        item = {"path": str(p), "fingerprint": c.fingerprint(p)}
        st = p.stat()
        os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))
        self.assertEqual(c.fingerprint(p), item["fingerprint"])
        c.safe_unlink(item)
        self.assertFalse(p.exists())

    def test_safe_unlink_rejects_hardlink_added_after_plan(self):
        p = self.cache()
        item = {"path": str(p), "fingerprint": c.fingerprint(p)}
        other = self.root / "other-cache-link"
        os.link(p, other)
        with self.assertRaises(c.CleanupBlocked):
            c.safe_unlink(item)
        self.assertTrue(p.exists())
        self.assertTrue(other.exists())

    def test_safe_unlink_rejects_parent_replaced_with_link(self):
        p=self.cache();item={'path':str(p),'fingerprint':c.fingerprint(p)}
        parent=p.parent;parent.rename(parent.with_name('hold'));parent.symlink_to(parent.with_name('hold'))
        with self.assertRaises(OSError):c.safe_unlink(item)
        self.assertTrue(p.exists())

    def make_local_run(self):
        output = self.root / "build/local-test"
        for relative in ("logs/iphone-build.log", "logs/watch-build.log",
                         "results/retained.json", "DerivedData/iphone/ModuleCache.noindex/file.pcm",
                         "DerivedData/iphone/Build/Products/app.app/binary",
                         "DerivedData/iphone/Build/Intermediates.noindex/source.swift"):
            path = output / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("** BUILD SUCCEEDED **")
        receipts.start(self.root, output, output / "DerivedData", "build", "dedicated")
        receipts.finish(output, 0)
        path = self.current / "release-state.json"
        state = json.loads(path.read_text())
        state["statusRecordedAt"] = "2100-01-01T00:00:00+00:00"
        self.write(path, state)
        return output

    def test_explicit_completed_local_run_only_loses_cache_and_preserves_evidence(self):
        output = self.make_local_run()
        before = self.manifest(output)
        result = c.cleanup(self.root, self.client, True)
        after = self.manifest(output)
        self.assertEqual(set(before) - set(after), {
            "DerivedData/iphone/ModuleCache.noindex/file.pcm",
            "DerivedData/iphone/Build/Products/app.app/binary"})
        self.assertTrue(all(before[name] == value for name, value in after.items()))
        self.assertEqual(result["retainedBefore"], result["retainedAfter"])
        self.assertEqual(c.cleanup(self.root, self.client, True)["deletedFiles"], 0)

    def test_shared_incomplete_changed_and_unregistered_local_runs_preserved(self):
        output = self.make_local_run()
        path = output / receipts.RECEIPT
        original = json.loads(path.read_text())
        for change in ({"cacheMode": "shared"}, {"status": "running"}, {"exitCode": 1}):
            self.write(path, dict(original, **change))
            result = c.cleanup(self.root, self.client)
            self.assertFalse(any(row.get("kind") == "local-run" for row in result["candidates"]))
        self.write(path, original)
        (output / "DerivedData/iphone/new.log").write_text("reused")
        result = c.cleanup(self.root, self.client)
        self.assertFalse(any(row.get("kind") == "local-run" for row in result["candidates"]))
        self.assertTrue(any("reused" in row["reason"] for row in result["kept"]))

    def test_registration_cannot_target_current_or_previous_release(self):
        self.make_local_run()
        for release in (self.current, self.previous):
            output = release / "test"
            self.write(output / receipts.RECEIPT, {"status": "completed"})
            receipts.register(self.root, output)
        result = c.cleanup(self.root, self.client)
        self.assertTrue(any("protected build" in row["reason"] for row in result["kept"]))
        self.assertTrue(self.cache(self.previous).exists())

    def test_receipt_change_after_planning_blocks(self):
        output = self.make_local_run()
        current = json.loads((self.current / "release-state.json").read_text())
        candidates, _ = c.local_candidates(self.root, current)
        (output / receipts.RECEIPT).write_text("{}")
        with self.assertRaisesRegex(c.CleanupBlocked, "receipt changed"):
            c.confirm_local_receipts(candidates)

    def test_nested_build_usage_counts_parent_once(self):
        central = self.root / "DeveloperBuildData/xDrip"
        work = central / "checkout"
        (work / "build").mkdir(parents=True)
        with mock.patch.object(c.Path, "home", return_value=self.root), \
                mock.patch.object(c, "command", return_value="42 path"):
            result = c.build_area_usage(work, {str(work): {}}, [work / "build"])
        self.assertEqual(result["paths"], {str(central): 42 * 1024})
        self.assertEqual(result["totalBytes"], 42 * 1024)

class ProcessGateTests(unittest.TestCase):
    def test_empty_process_inventory_is_not_idle(self):
        with mock.patch.object(c,"command",return_value=""):
            with self.assertRaises(c.CleanupBlocked):c.idle()

    def test_xcode_build_and_upload_processes_block(self):
        for name in ("Xcode","xcodebuild","SWBBuildService","xctest","altool","codesign","simctl"):
            rows="%d 1 python3\n999999 1 /tool/%s\n" % (os.getpid(),name)
            with self.subTest(name=name),mock.patch.object(c,"command",return_value=rows):
                with self.assertRaises(c.CleanupBlocked):c.idle()

    def test_xcode_ancestor_also_blocks(self):
        rows="%d 999999 python3\n999999 1 /tool/Xcode\n" % os.getpid()
        with mock.patch.object(c,"command",return_value=rows):
            with self.assertRaises(c.CleanupBlocked):c.idle()

    def test_other_release_script_blocks_without_logging_arguments(self):
        rows="%d 1 python3\n999999 1 /usr/bin/python3\n" % os.getpid()
        p=subprocess.CompletedProcess([],0,"python3 release-testflight.py upload --secret PRIVATE","")
        with mock.patch.object(c,"command",return_value=rows),mock.patch.object(c.subprocess,"run",return_value=p):
            with self.assertRaises(c.CleanupBlocked) as error:c.idle()
        self.assertNotIn("PRIVATE",str(error.exception))

    def test_lsof_only_accepts_clear_no_match(self):
        for code,out,err in ((0,"open file",""),(1,"","permission denied"),(2,"","")):
            with mock.patch.object(c.subprocess,"run",return_value=subprocess.CompletedProcess([],code,out,err)):
                with self.assertRaises(c.CleanupBlocked):c.ensure_unopened(["/synthetic"])
        with mock.patch.object(c.subprocess,"run",return_value=subprocess.CompletedProcess([],1,"","")):
            c.ensure_unopened(["/synthetic"])


class HostLockTests(unittest.TestCase):
    def test_second_process_cannot_acquire_lock(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'lock'
            env={k:v for k,v in os.environ.items() if k != locks.KEY}
            with mock.patch.dict(os.environ,env,clear=True),mock.patch.object(locks,'lock_path',return_value=path):
                with locks.build_lock():
                    code='import fcntl,sys; f=open(sys.argv[1],"r+"); fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)'
                    p=subprocess.run([sys.executable,'-c',code,str(path)],capture_output=True,env=env)
                    self.assertNotEqual(p.returncode,0)
                with locks.build_lock(): pass

    def test_build_child_drops_fd_but_parent_keeps_lock(self):
        # Use the real shared lock only when this test is already inside local-build.
        fd=locks.inherited_fd()
        if fd is None:
            with locks.build_lock():
                self.test_build_child_drops_fd_but_parent_keeps_lock()
            return
        code="import os,sys; assert 'XDRIP_BUILD_LOCK_FD' not in os.environ; "
        code+="assert not os.path.exists('/dev/fd/'+sys.argv[1])"
        p=subprocess.run([sys.executable,'-B',str(Path(locks.__file__)), '--child',sys.executable,'-c',code,str(fd)],
                         pass_fds=(fd,),capture_output=True,text=True)
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertEqual(locks.inherited_fd(),fd)

    def test_symlink_lock_is_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            p=Path(temp)/'lock';dest=Path(temp)/'secret';dest.write_text('keep');p.symlink_to(dest)
            with mock.patch.dict(os.environ,{k:v for k,v in os.environ.items() if k!=locks.KEY},clear=True),mock.patch.object(locks,'lock_path',return_value=p):
                with self.assertRaises(OSError):
                    with locks.build_lock():pass
            self.assertEqual(dest.read_text(),'keep')

if __name__=='__main__':
    unittest.main()
