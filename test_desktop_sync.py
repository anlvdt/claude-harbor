from unittest.mock import patch
import copy, importlib.util, json, tempfile, unittest, uuid
from pathlib import Path
spec = importlib.util.spec_from_file_location('sync', Path(__file__).with_name('desktop_sync.py'))
sync = importlib.util.module_from_spec(spec); spec.loader.exec_module(sync)

class SyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); sync.ROOT = Path(self.temp.name)
        self.home_patch = patch.object(Path, 'home', return_value=sync.ROOT/'home')
        self.home_patch.start(); self.addCleanup(self.home_patch.stop)
        sync.EXTERNAL_TARGETS = {}
        sync.inventory.EXTERNAL.clear(); sync.inventory.TRANSCRIPTS.clear()
        sync.HISTORY_ROOTS = []; sync.DESKTOP_ROOTS = []
        sync.live_cli_ids = lambda: {}
        sync.running_profiles = lambda: []
        sync.account_dir = lambda p: sync.gui(p) / 'claude-code-sessions/account/org'
        self.cli = str(uuid.uuid4()); self.local = 'local_' + str(uuid.uuid4())
        self.file = sync.code('magpie') / 'projects/-test' / (self.cli + '.jsonl')
        self.record = sync.account_dir('magpie') / (self.local + '.json')
        self.rows = []; self.d = {'sessionId': self.local, 'cliSessionId': self.cli, 'title': 'Test', 'cwd': '/test', 'model': 'mythos-magpie-1026517788'}
        self.turn(self.rows, self.d, 'one', self.cli)
        self.write(self.file, self.record, self.rows, self.d)

    def tearDown(self): self.temp.cleanup()
    def turn(self, rows, d, text, cli):
        rows.extend([
            {'type': 'user', 'uuid': str(uuid.uuid4()), 'sessionId': cli, 'cwd':'/test', 'timestamp': '2026-10-04T01:00:00Z', 'message': {'role': 'user', 'content': text}},
            {'type': 'assistant', 'uuid': str(uuid.uuid4()), 'sessionId': cli, 'cwd':'/test', 'timestamp': '2026-10-04T01:00:01Z', 'message': {'role': 'assistant', 'content': [{'type': 'text', 'text': text}], 'stop_reason': 'end_turn'}},
            {'type': 'system', 'subtype': 'stop_hook_summary', 'timestamp': '2026-10-04T01:00:02Z'}])
        d['lastAssistantUuid'] = rows[-2]['uuid']; d['completedTurns'] = d.get('completedTurns', 0) + 1
    def write(self, f, r, rows, d):
        f.parent.mkdir(parents=True, exist_ok=True); r.parent.mkdir(parents=True, exist_ok=True)
        f.write_text('\n'.join(json.dumps(x) for x in rows) + '\n'); r.write_text(json.dumps(d))
    def member(self, p):
        return next(sync.snapshot(q, path, d) for q, path, d in sync.records() if q == p)

    def test_fanout_idempotence_and_append(self):
        report = sync.sync_all(); self.assertEqual(report['sessions'], 1)
        self.assertEqual(len(sync.records()), len(sync.NAMES))
        paths = {p: str(path) for p, path, _ in sync.records()}
        self.assertEqual(len({d['cliSessionId'] for _, _, d in sync.records()}), 3)
        self.assertEqual(sync.sync_all()['filesChanged'], 0)
        self.turn(self.rows, self.d, 'two', self.cli); self.write(self.file, self.record, self.rows, self.d)
        sync.sync_all()
        self.assertEqual(paths, {p: str(path) for p, path, _ in sync.records()})
        self.assertTrue(all(s['signature'] == self.member('magpie')['signature'] for s in [self.member('pro1'), self.member('pro2')]))
        self.assertEqual(self.member('pro1')['record']['model'], 'sonnet')

    def test_divergence_preserves_both_branches(self):
        sync.sync_all()
        for p in ('pro1', 'pro2'):
            s = self.member(p); d = s['record']; f, rows = s['files'][d['cliSessionId']]
            self.turn(rows, d, p + '-branch', d['cliSessionId']); self.write(f, s['path'], rows, d)
        originals = {p: self.member(p)['signature'] for p in ('pro1', 'pro2')}
        report = sync.sync_all(); self.assertEqual(report['newBranches'], 1)
        self.assertEqual(len(sync.records()), 6)
        for p in sync.NAMES:
            signatures = [sync.snapshot(q, path, d)['signature'] for q, path, d in sync.records() if q == p]
            self.assertCountEqual(signatures, list(originals.values()))
        self.assertEqual(sync.sync_all()['filesChanged'], 0)

    def test_busy_and_running_refuse_writes(self):
        self.rows.append({'type': 'user', 'uuid': str(uuid.uuid4()), 'sessionId': self.cli, 'message': {'role': 'user', 'content': 'unfinished'}})
        self.write(self.file, self.record, self.rows, self.d)
        sync.running_profiles = lambda: ['magpie']
        sync.live_cli_ids = lambda: {'magpie':{self.cli}}
        self.assertEqual(len(sync.preflight()['busy']), 1)
        with self.assertRaises(ValueError): sync.sync_all()
        self.assertFalse((sync.ROOT / 'sync-state.json').exists())
        sync.running_profiles = lambda: ['magpie']
        with self.assertRaises(ValueError): sync.sync_all()

    def test_other_org_of_same_account_is_included(self):
        other = self.record.parent.parent / 'another-org' / self.record.name
        self.record.rename(other) if other.parent.exists() else None
        if not other.exists():
            other.parent.mkdir(); self.record.rename(other)
        self.assertEqual(len(sync.records()), 1)
        self.assertEqual(sync.sync_all()['sessions'], 1)
        self.assertEqual(len(sync.records()), len(sync.NAMES))

    def test_orphan_transcript_without_desktop_record_is_imported(self):
        self.record.unlink()
        report = sync.sync_all()
        self.assertEqual(report['sessions'],1)
        self.assertEqual(len(sync.records()),len(sync.NAMES))
        self.assertTrue(all(d['title']=='one' for _,_,d in sync.records()))
        self.assertEqual(sync.sync_all()['filesChanged'],0)

    def test_external_transcript_and_desktop_title_are_imported(self):
        external = Path(self.temp.name)/'original-code'; desktop=Path(self.temp.name)/'original-desktop'
        sync.HISTORY_ROOTS = [external]; sync.DESKTOP_ROOTS = [desktop]
        sync.EXTERNAL_TARGETS = {str(external): list(sync.NAMES)}
        self.file.rename(external/'projects/-test'/self.file.name) if (external/'projects/-test').exists() else None
        if self.file.exists():
            (external/'projects/-test').mkdir(parents=True); self.file.rename(external/'projects/-test'/self.file.name)
        self.record.unlink()
        legacy=desktop/'claude-code-sessions/old-account/old-org'/self.record.name
        legacy.parent.mkdir(parents=True); legacy.write_text(json.dumps({**self.d,'title':'Original Desktop Title'}))
        report=sync.sync_all(); self.assertEqual(report['sessions'],1)
        self.assertEqual(len(sync.records()),len(sync.NAMES))
        self.assertTrue(all(d['title']=='Original Desktop Title' for _,_,d in sync.records()))
        self.assertEqual(len({d['cliSessionId'] for _,_,d in sync.records()}),len(sync.NAMES))
        self.assertEqual(sync.sync_all()['sessions'],1)

    def test_failure_rolls_back(self):
        before = self.record.read_bytes()
        original = sync.copy_session
        def fail(source, profile, existing, gid, tx):
            if profile == 'pro2': raise OSError('injected write failure')
            return original(source, profile, existing, gid, tx)
        sync.copy_session = fail
        try:
            with self.assertRaises(OSError): sync.sync_all()
        finally: sync.copy_session = original
        self.assertEqual(self.record.read_bytes(), before)
        self.assertFalse((sync.ROOT / 'sync-state.json').exists())
        self.assertEqual(len(sync.records()), 1)

if __name__ == '__main__': unittest.main()
