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
        self.patches = [mock.patch.object(c, "idle"), mock.patch.object(c, "ensure_unopened"),
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
