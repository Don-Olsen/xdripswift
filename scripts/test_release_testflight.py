#!/usr/bin/env python3
"""Offline release guards using synthetic Git repositories and mocked Apple access."""

import importlib.util
import json
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
        # Never inherit an operator's real release authorization or API configuration.
        self.environment = mock.patch.dict(os.environ, {
            key: value for key, value in os.environ.items()
            if not key.startswith(("XDRIP_", "APP_STORE_CONNECT_", "ASC_"))
        }, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release-test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")
        self.git("config", "core.hooksPath", str(self.root / "build/empty-hooks"))
        (self.root / "xDrip").mkdir()
        self.version_file = self.root / "xDrip/Version.xcconfig"
        self.version_file.write_text(
            "XDRIP_MARKETING_VERSION = 7.0.0\nCURRENT_PROJECT_VERSION = 4264\n",
            encoding="utf-8",
        )
        (self.root / ".gitignore").write_text("build/\n", encoding="utf-8")
        (self.root / "docs").mkdir()
        (self.root / release.DOC).write_text("Known issue remains open.\n", encoding="utf-8")
        (self.root / "scripts").mkdir()
        builder = self.root / "scripts/local-build.sh"
        builder.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, subprocess, sys\n"
            "root = pathlib.Path.cwd()\n"
            "output = pathlib.Path(os.environ['XDRIP_OUTPUT_ROOT'])\n"
            "(output / 'results').mkdir(parents=True, exist_ok=True)\n"
            "with (root / 'build/invocations.jsonl').open('a') as stream:\n"
            " json.dump({'command': sys.argv[1], 'versionFile': (root / 'xDrip/Version.xcconfig').read_text(), "
            "'tree': subprocess.check_output(['git', 'write-tree'], text=True).strip()}, stream)\n"
            " stream.write('\\n')\n"
            "if sys.argv[1] == 'release-test':\n"
            " (output / 'results/stability-summary.json').write_text(json.dumps({"
            "'verificationPassed': True, 'counts': {'totalTestCount': 3, 'passedTests': 3, "
            "'failedTests': 0, 'skippedTests': 0}}))\n"
            "elif sys.argv[1] != 'python':\n"
            " raise SystemExit('Synthetic build stub rejects archive and upload')\n",
            encoding="utf-8",
        )
        builder.chmod(0o755)
        self.git("add", ".gitignore", "xDrip/Version.xcconfig", "docs/PROJECT-STATUS.md", "scripts/local-build.sh")
        self.git("commit", "-qm", "synthetic base")
        self.client = mock.Mock()
        self.client.snapshot.return_value = self.snapshot()
        self.client.upload_auth_args.return_value = ["--apiKey", "SYNTHETIC", "--apiIssuer", "synthetic-issuer"]

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root,
                                       stderr=subprocess.DEVNULL, text=True).strip()

    def remote(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        remote = Path(temporary.name) / "origin.git"
        subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
        subprocess.run(["git", "--git-dir", str(remote), "config", "core.hooksPath",
                        str(Path(temporary.name) / "empty-hooks")], check=True)
        self.git("remote", "add", "origin", str(remote))
        return remote

    def snapshot(self, *, next_build="4265", builds=None, uploads=None):
        builds = builds or []
        uploads = uploads or []
        return {"appID": release.APP_ID, "bundleID": "com.GFZ896KN66.xdripswift",
                "platform": "IOS", "version": "7.0.0", "observedAt": "2026-09-24T12:00:00+00:00",
                "builds": builds, "uploads": uploads, "highestBuild": str(int(next_build) - 1),
                "nextBuild": next_build, "versionBuilds": [r for r in builds if r["version"] == "7.0.0"],
                "versionUploads": [r for r in uploads if r["version"] == "7.0.0"]}

    def record(self, build="4265", **changes):
        result = {"id": "synthetic-build-" + build, "appID": release.APP_ID,
                  "version": "7.0.0", "build": build, "processingState": "VALID",
                  "betaInternalState": "IN_BETA_TESTING", "buildAudienceType": "INTERNAL_ONLY",
                  "expired": False}
        result.update(changes)
        return result

    def group(self, build="4265", **changes):
        result = {"id": "synthetic-group", "name": "Ole Internal", "isInternalGroup": True,
                  "buildID": "synthetic-build-" + build, "buildLinked": True}
        result.update(changes)
        return result

    def invocations(self):
        path = self.root / "build/invocations.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def artifacts(self):
        root = self.root / "build/synthetic-release"
        root.mkdir(parents=True, exist_ok=True)
        ipa = root / "synthetic.ipa"
        ipa.write_bytes(b"synthetic IPA, never uploaded")
        archive = root / "synthetic.xcarchive"
        archive.mkdir(exist_ok=True)
        (archive / "app").write_bytes(b"synthetic signed app")
        return root, ipa, archive, {
            "step": "verified", "ipa": str(ipa), "archive": str(archive),
            "ipaSha256": release.sha256_file(ipa), "archiveSha256": release.sha256_tree(archive),
            "version": "7.0.0", "build": "4265", "tag": "testflight-7.0.0-4265",
            "checkpoint": self.git("rev-parse", "HEAD"),
        }

    def attempt(self, root, state, outcome="uncertain"):
        release.save_state(root / "upload-attempt.json", {
            key: state[key] for key in ("checkpoint", "tag", "ipaSha256", "version", "build")
        } | {"startedAt": "2026-09-24T12:00:00+00:00", "outcome": outcome})

    def authorized(self, version="7.0.0"):
        return mock.patch.dict(os.environ, {"XDRIP_GO_UPLOAD": "YES", "XDRIP_GO_UPLOAD_VERSION": version})

    def prepared_checkpoint(self):
        self.remote()
        with mock.patch.object(release, "ensure_origin"), \
             mock.patch.object(release, "apple_client", return_value=self.client), \
             mock.patch.dict(os.environ, {"XDRIP_STAGED_DIFF_REVIEWED": "YES"}):
            version, number = release.prepare()
            root, path = release.release_paths(version, number)
            release.checkpoint(root, path, version, number, f"testflight-{version}-{number}")
            state = release.load_state(path, version, number)
            release.publish(path, state)
        return root, path, state

    def observation(self, state, *, record=None, group=None):
        return {"appID": release.APP_ID, "version": state["version"], "build": state["build"],
                "status": "internal-testing", "buildRecord": record or self.record(state["build"]),
                "group": group or self.group(state["build"])}

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

    def test_build_number_is_read_from_source_without_manual_input(self):
        self.assertEqual(release.version_and_build(), ("7.0.0", "4264"))
        with mock.patch.dict(os.environ, {"XDRIP_BUILD_NUMBER": "4265"}):
            with self.assertRaises(SystemExit):
                release.version_and_build()
        with mock.patch.dict(os.environ, {"XDRIP_BUILD_NUMBER": "4264"}):
            self.assertEqual(release.version_and_build(), ("7.0.0", "4264"))

    def test_prepare_selects_apple_number_and_only_adds_version_to_reviewed_index(self):
        (self.root / "Reading.swift").write_text("struct Reading {}\n", encoding="utf-8")
        self.git("add", "Reading.swift")
        original_blob = self.git("rev-parse", ":Reading.swift")
        self.client.snapshot.return_value = self.snapshot(
            next_build="4272", builds=[self.record("4271", version="6.0.0"), self.record("4269")])
        with mock.patch.object(release, "ensure_origin"), \
             mock.patch.object(release, "remote_ref", return_value=""), \
             mock.patch.object(release, "apple_client", return_value=self.client), \
             mock.patch.dict(os.environ, {"XDRIP_STAGED_DIFF_REVIEWED": "YES"}):
            self.assertEqual(release.prepare(), ("7.0.0", "4272"))
        self.assertEqual(self.git("diff", "--cached", "--name-only").splitlines(),
                         ["Reading.swift", "xDrip/Version.xcconfig"])
        self.assertEqual(self.git("rev-parse", ":Reading.swift"), original_blob)
        self.assertEqual(self.git("diff", "--name-only"), "")
        root, _ = release.release_paths("7.0.0", "4272")
        _, receipt = release.allocation_receipt(root, "7.0.0", "4272")
        self.assertEqual(receipt["snapshot"]["versionBuilds"], [self.record("4269")])
        self.assertEqual([r["command"] for r in self.invocations()], ["python"])
        self.assertIn("CURRENT_PROJECT_VERSION = 4264", self.invocations()[0]["versionFile"])

    def test_authentication_or_snapshot_failure_never_changes_version_or_index(self):
        before = self.version_file.read_bytes()
        tree = self.git("write-tree")
        for factory_fails in (True, False):
            with self.subTest(factory_fails=factory_fails):
                self.client.snapshot.side_effect = release.AppleError("synthetic access unavailable")
                factory = mock.Mock(side_effect=release.AppleError("synthetic authentication unavailable")) \
                    if factory_fails else mock.Mock(return_value=self.client)
                with mock.patch.object(release, "ensure_origin"), \
                     mock.patch.object(release, "apple_client", factory), \
                     mock.patch.dict(os.environ, {"XDRIP_STAGED_DIFF_REVIEWED": "YES"}):
                    with self.assertRaises(release.AppleError):
                        release.prepare()
                self.assertEqual(self.version_file.read_bytes(), before)
                self.assertEqual(self.git("write-tree"), tree)
                self.assertFalse((self.root / "build/release-automation/active.json").exists())

    def test_changed_build_is_tested_before_checkpoint_and_tag(self):
        root, path, state = self.prepared_checkpoint()
        calls = self.invocations()
        self.assertEqual([r["command"] for r in calls], ["python", "release-test"])
        self.assertIn("CURRENT_PROJECT_VERSION = 4264", calls[0]["versionFile"])
        self.assertIn("CURRENT_PROJECT_VERSION = 4265", calls[1]["versionFile"])
        self.assertNotEqual(calls[0]["tree"], calls[1]["tree"])
        self.assertEqual(calls[1]["tree"], state["tree"])
        self.assertEqual(self.git("rev-parse", state["tag"] + "^{tree}"), calls[1]["tree"])
        self.assertEqual(release.remote_ref("refs/tags/" + state["tag"] + "^{}"), state["checkpoint"])
        self.assertTrue(Path(state["tests"]["resultBundle"]).name == "AllTests.xcresult")

    def test_upload_requires_explicit_go_for_this_version(self):
        root, _, _, state = self.artifacts()
        for flags in ({}, {"XDRIP_GO_UPLOAD": "YES", "XDRIP_GO_UPLOAD_VERSION": "6.0.0"}):
            with self.subTest(flags=flags), mock.patch.object(release, "ensure_published"), \
                 mock.patch.object(release, "apple_client") as factory, mock.patch.dict(os.environ, flags):
                with self.assertRaises(SystemExit):
                    release.upload(root, root / "state.json", state)
                factory.assert_not_called()
                self.assertFalse((root / "upload-attempt.json").exists())

    def test_uncertain_attempt_queries_apple_and_never_retries_even_if_number_matches(self):
        root, _, _, state = self.artifacts()
        self.attempt(root, state)
        for records in ([], [self.record()]):
            with self.subTest(records=bool(records)):
                self.client.snapshot.return_value = self.snapshot(builds=records)
                self.client.snapshot.reset_mock()
                with mock.patch.object(release, "ensure_published"), \
                     mock.patch.object(release, "apple_client", return_value=self.client), \
                     mock.patch.object(release, "run") as command, self.authorized():
                    with self.assertRaisesRegex(SystemExit, "uncertain"):
                        release.upload(root, root / "state.json", state)
                    self.client.snapshot.assert_called_once_with("7.0.0")
                    command.assert_not_called()
                self.assertEqual(state["step"], "verified")

    def test_confirmed_attempt_resumes_observation_without_second_upload(self):
        root, _, _, state = self.artifacts()
        self.attempt(root, state, outcome="received")
        with mock.patch.object(release, "ensure_published"), \
             mock.patch.object(release, "apple_client", return_value=self.client), \
             mock.patch.object(release, "run") as command, self.authorized():
            release.upload(root, root / "state.json", state)
            command.assert_not_called()
            self.client.snapshot.assert_called_once_with("7.0.0")
        self.assertEqual(state["step"], "uploaded")

    def test_changed_archive_or_ipa_blocks_upload_before_attempt_marker(self):
        root, ipa, archive, state = self.artifacts()
        for target in (ipa, archive / "app"):
            original = target.read_bytes()
            target.write_bytes(b"changed after verification")
            with self.subTest(target=target.name), mock.patch.object(release, "ensure_published"), \
                 mock.patch.object(release, "apple_client") as factory, self.authorized():
                with self.assertRaises(SystemExit):
                    release.upload(root, root / "state.json", state)
                factory.assert_not_called()
                self.assertFalse((root / "upload-attempt.json").exists())
            target.write_bytes(original)

    def test_direct_upload_uses_exact_verified_ipa_and_persists_attempt_first(self):
        root, ipa, _, state = self.artifacts()
        calls = []
        def upload_command(args, **kwargs):
            marker = json.loads((root / "upload-attempt.json").read_text())
            self.assertEqual(marker["ipaSha256"], release.sha256_file(ipa))
            self.assertEqual(marker["outcome"], "uncertain")
            self.assertEqual(marker["checkpoint"], state["checkpoint"])
            self.assertEqual(self.client.snapshot.call_count, 1)
            calls.append(args)
            kwargs["log"].write_text('{"success": true}\n')
            return 0
        with mock.patch.object(release, "ensure_published"), \
             mock.patch.object(release, "apple_client", return_value=self.client), \
             mock.patch.object(release, "run", side_effect=upload_command), self.authorized():
            release.upload(root, root / "state.json", state)
        self.assertEqual(calls, [["xcrun", "altool", "--upload-package", str(ipa),
                                 "--apiKey", "SYNTHETIC", "--apiIssuer", "synthetic-issuer",
                                 "--output-format", "json"]])
        self.assertEqual(state["step"], "uploaded")
        self.assertEqual(state["ipaSha256"], release.sha256_file(ipa))
        self.assertEqual(json.loads((root / "upload-attempt.json").read_text())["outcome"], "received")

    def test_fresh_apple_collision_prevents_upload_and_attempt_creation(self):
        root, _, _, state = self.artifacts()
        self.client.snapshot.return_value = self.snapshot(uploads=[
            {"id": "synthetic-upload", "version": "7.0.0", "build": "4265", "state": "PROCESSING"}])
        with mock.patch.object(release, "ensure_published"), \
             mock.patch.object(release, "apple_client", return_value=self.client), \
             mock.patch.object(release, "run") as command, self.authorized():
            with self.assertRaises(release.SlotOccupied):
                release.upload(root, root / "state.json", state)
            command.assert_not_called()
        self.assertFalse((root / "upload-attempt.json").exists())

    def test_other_version_numeric_build_alias_also_blocks_upload(self):
        root, _, _, state = self.artifacts()
        for collection in ("builds", "uploads"):
            for alias in ("4265", "4265.0", "4265.0.0"):
                with self.subTest(collection=collection, alias=alias):
                    row = self.record(alias, version="6.0.0")
                    self.client.snapshot.return_value = self.snapshot(**{collection: [row]})
                    with mock.patch.object(release, "ensure_published"), \
                         mock.patch.object(release, "apple_client", return_value=self.client), \
                         mock.patch.object(release, "run") as command, self.authorized():
                        with self.assertRaises(release.SlotOccupied):
                            release.upload(root, root / "state.json", state)
                        command.assert_not_called()
                    self.assertFalse((root / "upload-attempt.json").exists())

    def test_prepare_reuse_preserves_allocation_bound_to_tested_checkpoint(self):
        root, _, state = self.prepared_checkpoint()
        allocation = root / "allocation.json"
        original = allocation.read_bytes()
        fresh = self.snapshot(next_build="4266", builds=[self.record("4264", version="6.0.0")])
        fresh["observedAt"] = "2026-09-24T12:05:00+00:00"
        self.client.snapshot.return_value = fresh
        with mock.patch.object(release, "ensure_origin"), \
             mock.patch.object(release, "apple_client", return_value=self.client), \
             mock.patch.dict(os.environ, {"XDRIP_STAGED_DIFF_REVIEWED": "YES"}):
            self.assertEqual(release.prepare(), ("7.0.0", "4265"))
        self.assertEqual(allocation.read_bytes(), original)
        self.assertEqual(release.sha256_file(allocation), state["allocationSha256"])
        observed = self.root / "build/release-automation/preflight" / state["tree"] / "apple-builds.json"
        self.assertEqual(json.loads(observed.read_text()), fresh)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_fixed_release_root_is_rejected_before_authentication_or_mutation(self):
        fixed = self.root / "build/shared-release-root"
        fixed.mkdir(parents=True)
        original = self.version_file.read_bytes()
        tree = self.git("write-tree")
        with mock.patch.object(release, "ensure_origin"), \
             mock.patch.object(release, "apple_client") as factory, \
             mock.patch.object(release, "run") as command, \
             mock.patch.dict(os.environ, {"XDRIP_RELEASE_ROOT": str(fixed),
                                         "XDRIP_STAGED_DIFF_REVIEWED": "YES"}):
            with self.assertRaisesRegex(SystemExit, "XDRIP_RELEASE_ROOT"):
                release.prepare()
            factory.assert_not_called()
            command.assert_not_called()
        self.assertEqual(self.version_file.read_bytes(), original)
        self.assertEqual(self.git("write-tree"), tree)
        self.assertEqual(list(fixed.iterdir()), [])
        self.assertFalse((self.root / "build/release-automation/active.json").exists())

    def test_completed_release_resumes_status_until_new_source_requires_new_tested_tag(self):
        root, path, state = self.prepared_checkpoint()
        state["step"] = "uploaded"
        state["ipaSha256"] = "synthetic-completed-ipa-hash"
        self.attempt(root, state, outcome="received")
        observation = self.observation(state)
        with mock.patch.object(release, "ensure_origin"):
            release.status(root, path, state, observation)
        old_source = state["checkpoint"]
        with mock.patch.object(release, "prepare") as prepare, \
             mock.patch.object(release, "checkpoint") as checkpoint, \
             mock.patch.object(release, "build") as build, \
             mock.patch.object(release, "upload") as upload, \
             mock.patch.object(release, "poll_apple", return_value=observation), \
             mock.patch.object(release, "status"), self.authorized():
            release.release_all()
            for mutation in (prepare, checkpoint, build, upload):
                mutation.assert_not_called()

        # A later reviewed app change needs a fresh build, exact-tree tests and tag.
        (self.root / "Reading.swift").write_text("struct NewReading {}\n", encoding="utf-8")
        self.git("add", "Reading.swift")
        self.client.snapshot.return_value = self.snapshot(next_build="4266", builds=[self.record("4265")])
        with mock.patch.object(release, "ensure_origin"), \
             mock.patch.object(release, "apple_client", return_value=self.client), \
             mock.patch.object(release, "build", side_effect=RuntimeError("synthetic stop at new archive")) as build, \
             mock.patch.object(release, "upload") as upload, \
             mock.patch.dict(os.environ, {"XDRIP_STAGED_DIFF_REVIEWED": "YES"}), self.authorized():
            with self.assertRaisesRegex(RuntimeError, "synthetic stop at new archive"):
                release.release_all()
            build.assert_called_once()
            upload.assert_not_called()
        new_source = self.git("rev-parse", "testflight-7.0.0-4266^{}")
        self.assertNotEqual(new_source, old_source)
        self.assertEqual(release.remote_ref("refs/tags/testflight-7.0.0-4265^{}"), old_source)
        self.assertEqual(release.remote_ref("refs/tags/testflight-7.0.0-4266^{}"), new_source)
        tests = [row for row in self.invocations() if row["command"] == "release-test"]
        self.assertEqual(len(tests), 2)
        self.assertEqual(tests[-1]["tree"], self.git("rev-parse", new_source + "^{tree}"))
        self.assertIn("CURRENT_PROJECT_VERSION = 4266", tests[-1]["versionFile"])
        self.assertEqual(self.git("show", new_source + ":Reading.swift"), "struct NewReading {}")

    def test_collision_retests_new_build_preserves_old_tag_and_uploads_once(self):
        self.remote()
        original_run = release.run
        uploads = []
        collided = False
        def snapshot(_):
            nonlocal collided
            if self.git("tag", "--list", "testflight-7.0.0-4265"):
                collided = True
            return self.snapshot(next_build="4266" if collided else "4265",
                                 builds=[self.record("4265")] if collided else [])
        self.client.snapshot.side_effect = snapshot
        self.client.build_status.side_effect = lambda version, number: self.record(number)
        self.client.ensure_internal_group.side_effect = lambda build_id, name: self.group(build_id.rsplit("-", 1)[1])
        def synthetic_archive(root, path, state):
            archive = root / "product.xcarchive"
            archive.mkdir(parents=True)
            (archive / "app").write_text(state["checkpoint"])
            ipa = root / "product.ipa"
            ipa.write_text(state["checkpoint"])
            state.update(step="built", archive=str(archive), ipa=str(ipa))
            release.save_state(path, state)
        def synthetic_verify(root, path, state):
            state.update(step="verified", ipaSha256=release.sha256_file(Path(state["ipa"])),
                         archiveSha256=release.sha256_tree(Path(state["archive"])))
            release.save_state(path, state)
        def safe_run(args, **kwargs):
            if args[:3] == ["xcrun", "altool", "--upload-package"]:
                uploads.append(args)
                kwargs["log"].write_text("synthetic upload succeeded\n")
                return 0
            return original_run(args, **kwargs)
        with mock.patch.object(release, "ensure_origin"), \
             mock.patch.object(release, "apple_client", return_value=self.client), \
             mock.patch.object(release, "build", side_effect=synthetic_archive), \
             mock.patch.object(release, "verify", side_effect=synthetic_verify), \
             mock.patch.object(release, "run", side_effect=safe_run), \
             mock.patch.dict(os.environ, {"XDRIP_STAGED_DIFF_REVIEWED": "YES"}), self.authorized():
            release.release_all()
        old_commit = self.git("rev-parse", "testflight-7.0.0-4265^{}")
        new_commit = self.git("rev-parse", "testflight-7.0.0-4266^{}")
        self.assertNotEqual(old_commit, new_commit)
        self.assertEqual(release.remote_ref("refs/tags/testflight-7.0.0-4265^{}"), old_commit)
        self.assertEqual(release.remote_ref("refs/tags/testflight-7.0.0-4266^{}"), new_commit)
        tests = [row for row in self.invocations() if row["command"] == "release-test"]
        self.assertEqual(len(tests), 2)
        self.assertEqual([row["tree"] for row in tests],
                         [self.git("rev-parse", commit + "^{tree}") for commit in (old_commit, new_commit)])
        self.assertIn("CURRENT_PROJECT_VERSION = 4265", tests[0]["versionFile"])
        self.assertIn("CURRENT_PROJECT_VERSION = 4266", tests[1]["versionFile"])
        self.assertEqual(len(uploads), 1)
        self.assertIn("testflight-7.0.0-4266", uploads[0][3])
        self.assertFalse((self.root / "build/testflight-7.0.0-4265/upload-attempt.json").exists())
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_poll_requires_internal_only_and_rechecks_testing_after_group_assignment(self):
        root, _, _, state = self.artifacts()
        state["step"] = "uploaded"
        self.client.build_status.side_effect = [self.record(betaInternalState="READY_FOR_BETA_TESTING"), self.record()]
        self.client.ensure_internal_group.return_value = self.group()
        with mock.patch.object(release, "apple_client", return_value=self.client):
            result = release.poll_apple(root, root / "state.json", state, timeout=0)
        self.assertEqual(result["status"], "internal-testing")
        self.assertEqual(self.client.build_status.call_count, 2)
        self.client.ensure_internal_group.assert_called_once_with("synthetic-build-4265", "Ole Internal")
        self.client.reset_mock()
        self.client.build_status.side_effect = None
        self.client.build_status.return_value = self.record(buildAudienceType="APP_STORE_ELIGIBLE")
        with mock.patch.object(release, "apple_client", return_value=self.client):
            result = release.poll_apple(root, root / "state.json", state, timeout=0)
        self.assertEqual(result["status"], "action-required")
        self.client.ensure_internal_group.assert_not_called()

    def test_poll_does_not_claim_testing_for_pending_or_unlinked_build(self):
        root, _, _, state = self.artifacts()
        state["step"] = "uploaded"
        for record, group in ((None, self.group()),
                              (self.record(processingState="PROCESSING"), self.group()),
                              (self.record(betaInternalState="READY_FOR_BETA_TESTING"), self.group()),
                              (self.record(), self.group(buildLinked=False))):
            with self.subTest(record=record, group=group):
                self.client.build_status.return_value = record
                self.client.ensure_internal_group.return_value = group
                with mock.patch.object(release, "apple_client", return_value=self.client):
                    result = release.poll_apple(root, root / "state.json", state, timeout=0)
                self.assertIn(result["status"], ("received", "processing"))

    def test_internal_status_rejects_wrong_group_audience_or_testing_state(self):
        root, path, state = self.prepared_checkpoint()
        state["step"] = "uploaded"
        original = (self.root / release.DOC).read_bytes()
        invalid = [self.observation(state, group=self.group(name="Another group")),
                   self.observation(state, group=self.group(isInternalGroup=False)),
                   self.observation(state, group=self.group(buildLinked=False)),
                   self.observation(state, group=self.group(buildID="another-build")),
                   self.observation(state, record=self.record(buildAudienceType="APP_STORE_ELIGIBLE")),
                   self.observation(state, record=self.record(betaInternalState="READY_FOR_BETA_TESTING")),
                   self.observation(state, record=self.record(expired=True))]
        for observation in invalid:
            with self.subTest(observation=observation), mock.patch.object(release, "ensure_origin"):
                with self.assertRaisesRegex(SystemExit, "Internal / Testing"):
                    release.status(root, path, state, observation)
                self.assertEqual((self.root / release.DOC).read_bytes(), original)

    def test_synthetic_checkpoint_push_tag_and_status_keep_tag_on_source(self):
        root, path, state = self.prepared_checkpoint()
        state["step"] = "uploaded"
        release.save_state(path, state)
        with mock.patch.object(release, "ensure_origin"):
            release.status(root, path, state, self.observation(state))
        self.assertNotEqual(self.git("rev-parse", "HEAD"), state["checkpoint"])
        self.assertEqual(self.git("rev-parse", state["tag"] + "^{}"), state["checkpoint"])
        self.assertEqual(release.remote_ref("refs/tags/" + state["tag"] + "^{}"), state["checkpoint"])
        self.assertEqual(self.git("diff", "--name-only", state["checkpoint"], "HEAD"), release.DOC.as_posix())
        document = (self.root / release.DOC).read_text()
        self.assertIn("Known issue remains open.", document)
        self.assertIn("Internal / Testing", document)
        self.assertIn("Ole Internal er bekræftet tilknyttet", document)
        self.assertEqual(state["appleStatus"], "internal-testing")


if __name__ == "__main__":
    unittest.main()
