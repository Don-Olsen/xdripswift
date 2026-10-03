#!/usr/bin/env python3
"""Offline receipt tests; raw XCResult tool responses use synthetic fixtures."""
import json
import os
import subprocess
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock

import local_run_receipt as r


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name).resolve()
        self.output = self.repo / "build/local-fixture"
        self.dd = self.output / "DerivedData"
        for relative, content in {
            "logs/all-xctest.log": "** TEST SUCCEEDED **\n",
            "logs/iphone-build.log": "** BUILD SUCCEEDED **\n",
            "logs/watch-build.log": "** BUILD SUCCEEDED **\n",
            "results/AllTests.xcresult/Data/result": "raw retained fixture",
            "DerivedData/all-tests/ModuleCache.noindex/test.pcm": "cache",
            "DerivedData/all-tests/Build/Intermediates.noindex/source.swift": "source",
        }.items():
            path = self.output / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        self.counts = {"totalTestCount": 2, "passedTests": 2, "failedTests": 0, "skippedTests": 0}
        self.summary = dict(self.counts, result="Passed")
        self.patch = mock.patch.object(r.subprocess, "check_output", return_value=json.dumps(self.summary))
        self.raw = self.patch.start()
        self.addCleanup(self.patch.stop)
        patch = mock.patch.object(r.subprocess, "run", return_value=subprocess.CompletedProcess([], 0))
        patch.start()
        self.addCleanup(patch.stop)
        saved = {"verificationPassed": True, "counts": self.counts,
                 "sourceCommit": "a" * 40, "resultBundle": str(self.output / "results/AllTests.xcresult")}
        (self.output / "results/stability-summary.json").write_text(json.dumps(saved))

    def receipt(self):
        return json.loads((self.output / r.RECEIPT).read_text())

    def complete(self):
        r.start(self.repo, self.output, self.dd, "release-test", "dedicated")
        r.finish(self.output, 0)
        return self.receipt()

    def validate(self, receipt):
        return r.validate(receipt, self.repo, self.output, time.time_ns() + 10**9)

    def test_completed_receipt_validates_raw_evidence_and_detects_reuse(self):
        receipt = self.complete()
        self.assertEqual(receipt["status"], "completed")
        self.assertEqual(self.validate(receipt), self.dd)
        path = self.dd / "all-tests/ModuleCache.noindex/test.pcm"
        path.unlink()  # A previous selective cleanup is valid and idempotent.
        self.assertEqual(self.validate(receipt), self.dd)
        path.write_text("new build reused this cache")
        with self.assertRaisesRegex(ValueError, "reused"):
            self.validate(receipt)

    def test_new_non_candidate_cache_file_also_detects_reuse(self):
        receipt = self.complete()
        (self.dd / "new.log").write_text("later build")
        with self.assertRaisesRegex(ValueError, "reused"):
            self.validate(receipt)

    def test_running_failed_and_shared_are_preserved(self):
        r.start(self.repo, self.output, self.dd, "release-test", "dedicated")
        with self.assertRaisesRegex(ValueError, "did not complete"):
            self.validate(self.receipt())
        r.finish(self.output, 1)
        with self.assertRaisesRegex(ValueError, "did not complete"):
            self.validate(self.receipt())
        receipt = self.receipt()
        receipt["cacheMode"] = "shared"
        with self.assertRaisesRegex(ValueError, "Shared"):
            self.validate(receipt)

    def test_output_reuse_cannot_keep_old_completed_receipt(self):
        self.complete()
        with self.assertRaisesRegex(ValueError, "already has"):
            r.start(self.repo, self.output, self.dd, "release-test", "dedicated")

    def test_newer_run_or_changed_log_or_result_is_preserved(self):
        receipt = self.complete()
        with self.assertRaisesRegex(ValueError, "Newer"):
            r.validate(receipt, self.repo, self.output, 1)
        (self.output / "logs/all-xctest.log").write_text("changed")
        with self.assertRaisesRegex(ValueError, "evidence changed"):
            self.validate(receipt)

    def test_failed_raw_tests_cannot_use_successful_saved_summary(self):
        self.raw.return_value = json.dumps(dict(self.summary, result="Failed", failedTests=1))
        with self.assertRaisesRegex(ValueError, "XCResult"):
            r.inspect_legacy(self.repo, self.output, "release-test")

    def test_unverified_completion_does_not_authorize_cleanup(self):
        self.raw.return_value = json.dumps(dict(self.summary, result="Failed", failedTests=1))
        receipt = self.complete()
        self.assertEqual(receipt["status"], "unverified")
        with self.assertRaisesRegex(ValueError, "did not complete"):
            self.validate(receipt)

    def test_legacy_inspection_preserves_actual_provenance_and_source(self):
        receipt = r.inspect_legacy(self.repo, self.output, "release-test")
        self.assertEqual(receipt["status"], "legacy-inspected")
        self.assertNotIn("exitCode", receipt)
        self.assertEqual(receipt["evidence"]["sourceCommitFromEvidence"], "a" * 40)
        self.assertEqual(self.validate(receipt), self.dd)
        self.assertFalse((self.output / r.RECEIPT).exists())

    def test_terminal_failure_after_success_is_rejected(self):
        (self.output / "logs/all-xctest.log").write_text("** TEST SUCCEEDED **\n** TEST FAILED **")
        with self.assertRaisesRegex(ValueError, "terminal marker"):
            r.inspect_legacy(self.repo, self.output, "release-test")

    def test_legacy_commit_missing_from_repository_blocks_registration(self):
        with mock.patch.object(r.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)):
            with self.assertRaisesRegex(ValueError, "source commit is absent"):
                r.inspect_legacy(self.repo, self.output, "release-test")

    def test_symlink_and_hardlink_evidence_are_rejected(self):
        path = self.output / "logs/link"
        path.symlink_to(self.output / "logs/all-xctest.log")
        with self.assertRaisesRegex(ValueError, "Linked"):
            r.inspect_legacy(self.repo, self.output, "release-test")
        path.unlink()
        os.link(self.output / "logs/all-xctest.log", path)
        with self.assertRaisesRegex(ValueError, "Linked"):
            r.inspect_legacy(self.repo, self.output, "release-test")


if __name__ == "__main__":
    unittest.main()
