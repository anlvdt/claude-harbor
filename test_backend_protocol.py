import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import manager
import profile_store as store


class DesktopProtocolTests(unittest.TestCase):
    def invoke(self, arguments):
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            status = manager.main(arguments)
        return status, output.getvalue(), errors.getvalue()

    def test_capability_handshake_never_reads_profiles(self):
        with patch.object(manager, 'configure', side_effect=AssertionError('read profile')):
            status, output, errors = self.invoke(['--desktop-api', '1', 'capabilities'])
        response = json.loads(output)
        self.assertEqual(status, 0)
        self.assertEqual(errors, '')
        self.assertEqual(response['protocolVersion'], 1)
        self.assertTrue(response['ok'])
        self.assertIn('structured_errors', response['result']['features'])
        self.assertIn('profile_health', response['result']['features'])

    def test_unsupported_protocol_never_dispatches(self):
        with patch.object(manager, 'select_profile') as select:
            status, output, _ = self.invoke(['--desktop-api', '99', 'select', 'ptest', 'true'])
        select.assert_not_called()
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(output)['error']['code'], 'protocol_incompatible')

    def test_success_keeps_legacy_cli_shape(self):
        with patch.object(manager, 'status', return_value={'profiles': []}):
            status, output, _ = self.invoke(['status'])
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(output), {'profiles': []})

    def test_desktop_error_never_exports_raw_exception(self):
        with patch.object(manager, 'status', side_effect=ValueError('Bearer secret-cookie transcript private@email.test')):
            status, output, errors = self.invoke(['--desktop-api', '1', 'status'])
        self.assertEqual(status, 1)
        response = json.loads(output)
        self.assertFalse(response['ok'])
        self.assertEqual(response['error']['code'], 'operation_failed')
        self.assertTrue(response['error']['remediation'])
        self.assertNotIn('secret-cookie', output + errors)
        self.assertNotIn('private@email', output + errors)

    def test_lock_error_has_stable_code(self):
        with patch.object(manager, 'select_profile', side_effect=BlockingIOError()):
            status, output, _ = self.invoke(['--desktop-api', '1', 'select', 'ptest', 'true'])
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(output)['error']['code'], 'store_busy')

    def test_invalid_selection_argument_cannot_disable_profile(self):
        with patch.object(manager, 'select_profile') as select:
            status, output, _ = self.invoke(['--desktop-api', '1', 'select', 'ptest', 'typo'])
        select.assert_not_called()
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(output)['error']['code'], 'invalid_request')

    def test_missing_argument_is_structured(self):
        status, output, _ = self.invoke(['--desktop-api', '1', 'repair'])
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(output)['error']['code'], 'invalid_request')

    def test_expected_create_failures_have_actionable_codes(self):
        for name in ('', 'bad/name'):
            with self.subTest(name=name):
                status, output, _ = self.invoke(['--desktop-api', '1', 'create', name, 'claude'])
                self.assertEqual(status, 1)
                self.assertEqual(json.loads(output)['error']['code'], 'invalid_profile_name')
        with tempfile.TemporaryDirectory() as temp, patch.object(manager, 'SOURCE', Path(temp)/'missing.app'):
            status, output, _ = self.invoke(['--desktop-api', '1', 'create', 'Test', 'claude'])
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(output)['error']['code'], 'source_unavailable')

    def test_duplicate_profile_name_is_actionable_without_creating_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            with patch.object(manager, 'ROOT', root), patch.object(manager, 'SOURCE', root), \
                 patch('manager.Path.home', return_value=root), \
                 patch.object(store, 'load', return_value=[{'name':'Claude Test'}]), \
                 patch.object(manager, 'running', return_value=[]):
                status, output, _ = self.invoke(['--desktop-api', '1', 'create', 'Test', 'claude'])
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(output)['error']['code'], 'duplicate_profile')

    def test_verify_failure_remains_an_error_with_machine_code(self):
        report = {k: [] for k in ('missingTranscripts', 'conversationMismatches', 'auxiliaryMismatches', 'duplicateMembers', 'recordErrors')}
        report['incompleteGroups'] = 1
        with tempfile.TemporaryDirectory() as temp, patch.object(manager, 'ROOT', Path(temp)), \
             patch.object(manager, 'configure', return_value=([], [])), \
             patch.object(manager.sync, 'NAMES', {'ptest': 'Test'}), \
             patch.object(manager, 'running', return_value=[]), \
             patch('verify_coverage.verify', return_value=report):
            status, output, _ = self.invoke(['--desktop-api', '1', 'verify'])
            saved = Path(temp)/'last-verification.json'
            self.assertTrue(saved.exists(), 'Verification diagnostics must remain available after a failure')
            self.assertEqual(json.loads(saved.read_text()), report)
            self.assertEqual(saved.stat().st_mode & 0o777, 0o600)
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(output)['error']['code'], 'verification_failed')


class ProfileHealthStatusTests(unittest.TestCase):
    def test_malformed_optional_report_fields_do_not_break_profile_loading(self):
        base=dict(profiles=2, sessions=4, newBranches=0, filesChanged=6, backup='fixture')
        for extra in ({'warnings':'bad'}, {'warnings':True}, {'warnings':-1}, {'pending':[1]}, {'pending':'bad'}, {'profiles':True}):
            with self.subTest(extra=extra), tempfile.TemporaryDirectory() as temp, \
                 patch.object(manager, 'ROOT', Path(temp)), \
                 patch.object(manager, 'configure', return_value=([], [])), \
                 patch.object(manager.sync, 'running_profiles', return_value=[]):
                (Path(temp)/'last-sync.json').write_text(json.dumps({**base, **extra}))
                result=manager.status()
                self.assertEqual(result['profiles'], [])
                self.assertIsNone(result['lastSync'])
                self.assertTrue(result['pending'])

    def test_health_is_visible_even_if_profile_is_not_ready(self):
        profile = dict(id='ptest', name='Test', kind='claude', bundle='/tmp/Test.app', bundleID='test', model='sonnet')
        faults = [{'profile': 'ptest', 'code': 'missing_binary', 'detail': 'Missing Claude', 'blocking': True}]
        with tempfile.TemporaryDirectory() as temp, patch.object(manager, 'ROOT', Path(temp)), \
             patch.object(manager, 'configure', return_value=([profile], ['not ready'])), \
             patch.object(manager.sync, 'running_profiles', return_value=[]), \
             patch.object(store, 'account', side_effect=ValueError('not ready')), \
             patch.object(manager.profile_health, 'inspect_profile', return_value=faults):
            result = manager.status()
        self.assertFalse(result['profiles'][0]['ready'])
        self.assertEqual(result['profiles'][0]['health'], faults)

    def test_check_reports_stale_selected_clone_before_closing_apps(self):
        profile = dict(id='ptest', name='Test', syncEnabled=True)
        faults = [{'profile': 'ptest', 'code': 'clone_version_changed', 'detail': 'Repair clone', 'blocking': True}]
        with patch.object(manager, 'configure', return_value=([profile], [])), \
             patch.object(manager.sync, 'NAMES', {'ptest': 'Test', 'pother': 'Other'}), \
             patch.object(manager.profile_health, 'inspect_profile', return_value=faults), \
             patch.object(manager.sync, 'preflight', return_value={'busy': [], 'errors': [], 'running': ['ptest']}):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                status = manager.main(['--desktop-api', '1', 'check'])
        self.assertEqual(status, 1)
        self.assertEqual(json.loads(output.getvalue())['error']['code'], 'clone_stale')
