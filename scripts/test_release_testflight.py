#!/usr/bin/env python3
"""Offline guard tests for the TestFlight release sequence."""

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("release-testflight.py")
SPEC = importlib.util.spec_from_file_location("release_testflight", SCRIPT)
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root_patch = mock.patch.object(release, "ROOT", self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release-test@example.invalid")
        (self.root / "xDrip").mkdir()
        (self.root / "xDrip/Version.xcconfig").write_text(
            "XDRIP_MARKETING_VERSION = 7.0.0\nCURRENT_PROJECT_VERSION = 4264\n",
            encoding="utf-8",
        )
        self.git("add", "xDrip/Version.xcconfig")
        self.git("commit", "-qm", "synthetic base")

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.root, check=True,
                       stdout=subprocess.DEVNULL)

    def artifacts(self):
        ipa = self.root / "synthetic.ipa"
        ipa.write_bytes(b"synthetic IPA, never uploaded")
        archive = self.root / "synthetic.xcarchive"
        archive.mkdir()
        (archive / "app").write_bytes(b"synthetic signed app")
        return ipa, archive, {
            "step": "verified", "ipa": str(ipa), "archive": str(archive),
            "ipaSha256": release.sha256_file(ipa),
            "archiveSha256": release.sha256_tree(archive),
        }

    def test_untracked_source_blocks_test_receipt_until_staged(self):
        (self.root / "Reading.swift").write_text("struct Reading {}\n", encoding="utf-8")
        with self.assertRaises(SystemExit):
            release.ensure_candidate_matches_index()
        self.git("add", "Reading.swift")
        release.ensure_candidate_matches_index()

    def test_signing_key_in_index_blocks_checkpoint(self):
        (self.root / "AuthKey_example.p8").write_text("synthetic\n", encoding="utf-8")
        self.git("add", "AuthKey_example.p8")
        with self.assertRaises(SystemExit):
            release.ensure_candidate_matches_index()

    def test_nested_archive_product_in_index_blocks_checkpoint(self):
        product = self.root / "outside.xcarchive/Info.plist"
        product.parent.mkdir()
        product.write_text("synthetic", encoding="utf-8")
        self.git("add", "outside.xcarchive/Info.plist")
        with self.assertRaises(SystemExit):
            release.ensure_candidate_matches_index()

    def test_build_number_must_be_checked_into_source(self):
        with mock.patch.dict(os.environ, {"XDRIP_BUILD_NUMBER": "4265"}):
            with self.assertRaises(SystemExit):
                release.version_and_build()
        with mock.patch.dict(os.environ, {"XDRIP_BUILD_NUMBER": "4264"}):
            self.assertEqual(release.version_and_build(), ("7.0.0", "4264"))

    def test_upload_requires_explicit_go(self):
        _, _, state = self.artifacts()
        with mock.patch.object(release, "ensure_published"), \
             mock.patch.dict(os.environ, {"XDRIP_GO_UPLOAD": "",
                                      "XDRIP_ASC_UPLOAD_SLOT_CONFIRMED": "YES"}):
            with self.assertRaises(SystemExit):
                release.upload(self.root, self.root / "state.json", state)
        self.assertFalse((self.root / "upload-attempt.json").exists())

    def test_upload_attempt_is_never_retried_automatically(self):
        _, _, state = self.artifacts()
        (self.root / "upload-attempt.json").write_text("{}", encoding="utf-8")
        with mock.patch.object(release, "ensure_published"), \
             mock.patch.dict(os.environ, {"XDRIP_GO_UPLOAD": "YES",
                                      "XDRIP_ASC_UPLOAD_SLOT_CONFIRMED": "YES"}):
            with self.assertRaises(SystemExit):
                release.upload(self.root, self.root / "state.json", state)

    def test_archive_change_blocks_upload_before_attempt_marker(self):
        _, archive, state = self.artifacts()
        (archive / "app").write_bytes(b"changed after verification")
        with mock.patch.object(release, "ensure_published"), \
             mock.patch.dict(os.environ, {"XDRIP_GO_UPLOAD": "YES",
                                      "XDRIP_ASC_UPLOAD_SLOT_CONFIRMED": "YES"}):
            with self.assertRaises(SystemExit):
                release.upload(self.root, self.root / "state.json", state)
        self.assertFalse((self.root / "upload-attempt.json").exists())

    def test_synthetic_checkpoint_push_tag_and_status_keep_tag_on_source(self):
        with tempfile.TemporaryDirectory() as remote_parent:
            remote = Path(remote_parent) / "origin.git"
            subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
            self.git("remote", "add", "origin", str(remote))
            (self.root / "scripts").mkdir()
            fake_build = self.root / "scripts/local-build.sh"
            fake_build.write_text(
                "#!/bin/sh\n"
                "mkdir -p \"$XDRIP_OUTPUT_ROOT/results\"\n"
                "printf '%s\\n' '{\"verificationPassed\":true,\"counts\":"
                "{\"totalTestCount\":1,\"passedTests\":1,\"failedTests\":0,"
                "\"skippedTests\":0}}' > \"$XDRIP_OUTPUT_ROOT/results/stability-summary.json\"\n",
                encoding="utf-8",
            )
            fake_build.chmod(0o755)
            (self.root / "docs").mkdir()
            doc = self.root / "docs/PROJECT-STATUS.md"
            doc.write_text("Known issue remains open.\n", encoding="utf-8")
            (self.root / ".gitignore").write_text("build/\n", encoding="utf-8")
            self.git("add", ".gitignore", "scripts/local-build.sh", "docs/PROJECT-STATUS.md")
            root = self.root / "build/testflight-7.0.0-4264"
            path = root / "release-state.json"
            flags = {"XDRIP_BUILD_NUMBER": "4264", "XDRIP_ASC_BUILD_CONFIRMED": "YES",
                     "XDRIP_STAGED_DIFF_REVIEWED": "YES"}
            with mock.patch.object(release, "ensure_origin"), mock.patch.dict(os.environ, flags):
                release.checkpoint(root, path, "7.0.0", "4264", "testflight-7.0.0-4264")
                state = release.load_state(path, "7.0.0", "4264")
                self.assertEqual(state["step"], "checkpointed")
                release.publish(path, state)
                self.assertEqual(state["step"], "tagged")
                self.assertEqual(release.remote_ref("refs/tags/testflight-7.0.0-4264^{}"),
                                 state["checkpoint"])
                state["step"] = "uploaded"  # Synthetic Apple completion; no upload command runs.
                release.save_state(path, state)
                with mock.patch.dict(os.environ, {
                    "XDRIP_ASC_STATUS": "internal-testing",
                    "XDRIP_ASC_BUILD_URL": "https://appstoreconnect.apple.com/teams/test/apps/6795645396/testflight/ios/test",
                    "XDRIP_ASC_INTERNAL_GROUP": "Existing Internal Group",
                }):
                    release.status(root, path, state)
                self.assertNotEqual(release.git("rev-parse", "HEAD"), state["checkpoint"])
                self.assertEqual(release.git("rev-parse", "refs/tags/testflight-7.0.0-4264^{}"),
                                 state["checkpoint"])
                self.assertIn("Known issue remains open.", doc.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
