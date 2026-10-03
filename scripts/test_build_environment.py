#!/usr/bin/env python3
"""No Xcode or filesystem mutations outside synthetic temporary fixtures."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
import build_environment as b

class BuildEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.attrs = mock.patch.object(b, 'attributes', return_value=[])
        self.attrs.start(); self.addCleanup(self.attrs.stop)
        self.disk = mock.patch.object(b.shutil, 'disk_usage',
                                     return_value=mock.Mock(free=20 * 1024 ** 3))
        self.disk.start(); self.addCleanup(self.disk.stop)

    def check(self, repo=None, output=None):
        return b.check_environment(repo or self.root, output or self.root/'new/output',
                                   self.root/'new/cache')

    def test_local_paths_pass_without_creating_output(self):
        self.assertEqual(self.check()['source'], 20 * 1024 ** 3)
        self.assertFalse((self.root/'new').exists())

    def test_synced_ancestor_blocks_before_any_build(self):
        for marker in ('com.apple.file-provider-domain-id', 'com.apple.fileprovider.fpfs#P'):
            with self.subTest(marker=marker), mock.patch.object(
                    b, 'attributes', side_effect=lambda p: [marker] if p==self.root.parent else []):
                with self.assertRaisesRegex(b.EnvironmentBlocked, 'File Provider'):
                    self.check()

    def test_link_to_synced_folder_is_not_a_bypass(self):
        target=self.root/'sync'; target.mkdir()
        link=self.root/'link'; link.symlink_to(target, target_is_directory=True)
        with mock.patch.object(b, 'attributes', side_effect=lambda p:
                               ['com.apple.file-provider-domain-id'] if p==target else []):
            with self.assertRaises(b.EnvironmentBlocked):self.check(repo=link)

    def test_synced_output_is_rejected_even_with_local_source(self):
        output=self.root/'sync'; output.mkdir()
        with mock.patch.object(b, 'attributes', side_effect=lambda p:
                               ['com.apple.fileprovider.detached#B'] if p==output else []):
            with self.assertRaises(b.EnvironmentBlocked):self.check(output=output/'new')

    def test_low_disk_space_is_rejected(self):
        with mock.patch.object(b.shutil, 'disk_usage', return_value=mock.Mock(free=9*1024**3)):
            with self.assertRaisesRegex(b.EnvironmentBlocked, 'at least 10 GiB'):
                self.check()

    def test_exact_disk_threshold_is_accepted(self):
        with mock.patch.object(b.shutil, 'disk_usage', return_value=mock.Mock(free=b.MIN_FREE_BYTES)):
            self.check()

    def test_existing_file_is_not_valid_output_root(self):
        output=self.root/'file'; output.write_text('keep')
        with self.assertRaises(b.EnvironmentBlocked):self.check(output=output)
        self.assertEqual(output.read_text(),'keep')

    def test_unreadable_disk_state_is_rejected(self):
        with mock.patch.object(b.shutil,'disk_usage',side_effect=OSError('unknown')):
            with self.assertRaisesRegex(b.EnvironmentBlocked,'Cannot measure'):self.check()

class AttributeReaderTests(unittest.TestCase):
    def test_error_or_timeout_does_not_guess_unsynced(self):
        for response in (subprocess.CompletedProcess([],1,'','denied'),
                         subprocess.TimeoutExpired('xattr',5)):
            patch = {'side_effect':response} if isinstance(response,Exception) else {'return_value':response}
            with mock.patch.object(b.subprocess,'run',**patch):
                with self.assertRaises(b.EnvironmentBlocked):b.attributes(Path('/synthetic'))

if __name__ == '__main__':unittest.main()
