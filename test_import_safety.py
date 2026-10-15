import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import manager
from backend_protocol import BackendError


class ImportSourceSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root/'projects/example').mkdir(parents=True)
        self.sid = '40f5f586-34e5-4906-9dc5-6771c2e2d034'
        (self.root/'projects/example'/(self.sid+'.jsonl')).write_text('')

    def assert_rejected(self, commands, output='', code='import_source_busy', status=0, stderr=''):
        with patch.object(manager.sync, 'processes', return_value=commands), \
             patch.object(manager.subprocess, 'run', return_value=subprocess.CompletedProcess([],status,output,stderr)):
            with self.assertRaises(BackendError) as caught:
                manager.require_idle_import_source(self.root)
        self.assertEqual(caught.exception.code, code)

    def test_session_process_between_writes_is_rejected(self):
        self.assert_rejected(['/opt/bin/claude --resume '+self.sid])

    def test_explicit_source_process_is_rejected(self):
        self.assert_rejected(['/opt/bin/claude --config-dir '+str(self.root)])

    def test_default_source_with_live_claude_is_rejected(self):
        with patch.object(manager.Path, 'home', return_value=self.root):
            self.root = self.root/'.claude'
            (self.root/'projects').mkdir(parents=True)
            self.assert_rejected(['/opt/bin/claude'])

    def test_open_write_and_readwrite_descriptors_are_rejected(self):
        for access in ('aw','au'):
            self.assert_rejected([],output='p100\nf3\n'+access+'\n')

    def test_uninspectable_source_fails_closed(self):
        self.assert_rejected([],code='import_source_unchecked',status=1,stderr='Permission denied')
        with patch.object(manager.sync,'processes',return_value=[]), \
             patch.object(manager.subprocess,'run',side_effect=subprocess.TimeoutExpired('lsof',15)):
            with self.assertRaises(BackendError) as caught:
                manager.require_idle_import_source(self.root)
        self.assertEqual(caught.exception.code,'import_source_unchecked')

    def test_readonly_archived_source_can_be_imported(self):
        with patch.object(manager.sync,'processes',return_value=['/bin/echo '+self.sid]), \
             patch.object(manager.subprocess,'run',return_value=subprocess.CompletedProcess([],0,'p100\nf3\nar\n','')):
            manager.require_idle_import_source(self.root)

    @unittest.skipUnless(Path('/usr/sbin/lsof').exists(),'macOS lsof required')
    def test_real_open_writer_is_detected_and_closed_source_is_allowed(self):
        with patch.object(manager.sync,'processes',return_value=[]):
            with (self.root/'writer.jsonl').open('w') as writer:
                writer.write('fixture'); writer.flush()
                with self.assertRaises(BackendError) as caught:
                    manager.require_idle_import_source(self.root)
                self.assertEqual(caught.exception.code,'import_source_busy')
            manager.require_idle_import_source(self.root)


if __name__ == '__main__':
    unittest.main()
