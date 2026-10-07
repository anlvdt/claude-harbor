import json, tempfile, unittest, uuid
from pathlib import Path
from unittest.mock import patch
import profile_store as store
import test_desktop_sync as fixture
sync=fixture.sync

class ManyProfilesTests(fixture.SyncTests):
    def setUp(self):
        super().setUp(); self.original_names=sync.NAMES
        sync.NAMES={**sync.NAMES,'fourth':'Claude Fourth'}
        sync.PROFILE_MODELS={'fourth':'custom-model'}
    def tearDown(self):
        sync.NAMES=self.original_names;sync.PROFILE_MODELS={};super().tearDown()
    def test_fanout_idempotence_and_append(self):
        report=sync.sync_all();self.assertEqual(report['profiles'],4)
        self.assertEqual(len(sync.records()),4)
        self.assertEqual(self.member('fourth')['record']['model'],'custom-model')
        self.assertEqual(sync.sync_all()['filesChanged'],0)
        self.turn(self.rows,self.d,'second-turn',self.cli);self.write(self.file,self.record,self.rows,self.d)
        sync.sync_all()
        self.assertEqual(self.member('fourth')['signature'],self.member('magpie')['signature'])
    # Reuse branch, rollback, import tests with a fourth independent target.
    def test_divergence_preserves_both_branches(self):
        sync.sync_all()
        for p in ('pro1','fourth'):
            s=self.member(p);d=s['record'];f,rows=s['files'][d['cliSessionId']]
            self.turn(rows,d,p+'-branch',d['cliSessionId']);self.write(f,s['path'],rows,d)
        report=sync.sync_all();self.assertEqual(report['newBranches'],1)
        self.assertEqual(len(sync.records()),8)
        self.assertEqual(sync.sync_all()['filesChanged'],0)

class RegistryTests(unittest.TestCase):
    def test_new_profile_waits_for_real_code_identity(self):
        with tempfile.TemporaryDirectory() as temp,patch.object(store,'ROOT',Path(temp)):
            p={'id':'pnew','kind':'claude'}
            with self.assertRaisesRegex(ValueError,'Đăng nhập'):store.account(p)
            aid=str(uuid.uuid4());org=str(uuid.uuid4());g=store.gui(p);g.mkdir(parents=True)
            (g/'config.json').write_text(json.dumps({'lastKnownAccountUuid':aid}))
            with self.assertRaisesRegex(ValueError,'tạo một phiên'):store.account(p)
            expected=g/'claude-code-sessions'/aid/org;expected.mkdir(parents=True)
            self.assertEqual(store.account(p),expected)
    def test_invalid_profile_id_cannot_escape_root(self):
        with tempfile.TemporaryDirectory() as temp,patch.object(store,'REGISTRY',Path(temp)/'profiles.json'):
            store.REGISTRY.write_text(json.dumps({'profiles':[{'id':'../bad'}]}))
            with self.assertRaises(ValueError):store.load()

class RuntimeTests(unittest.TestCase):
    def test_fresh_runtime_contains_no_profiles_or_login_data(self):
        import bootstrap
        with tempfile.TemporaryDirectory() as temp:
            base=Path(temp);destination=base/'data';source=base/'bundle';source.mkdir()
            for name in bootstrap.FILES:(source/name).write_text('bundled '+name)
            with patch.object(store,'ROOT',destination),patch.object(store,'REGISTRY',destination/'profiles.json'):
                bootstrap.install_runtime(source)
                self.assertEqual(store.load(),[])
                self.assertFalse((destination/'profiles').exists())
                self.assertEqual((destination/'runtimes'/json.loads((destination/'current-runtime.json').read_text())['generation']/'manager.py').read_text(),'bundled manager.py')
    def test_runtime_update_preserves_profile_registry_and_history(self):
        import bootstrap
        with tempfile.TemporaryDirectory() as temp:
            base=Path(temp);destination=base/'data';source=base/'bundle';source.mkdir();destination.mkdir()
            for name in bootstrap.FILES:(source/name).write_text('updated '+name)
            registry=destination/'profiles.json';registry.write_text(json.dumps({'profiles':[{'id':'ptest','name':'Test'}]}))
            history=destination/'profiles/ptest/code/projects/example/test.jsonl';history.parent.mkdir(parents=True);history.write_text('private history')
            (destination/'manager.py').write_text('old runtime')
            with patch.object(store,'ROOT',destination),patch.object(store,'REGISTRY',registry):
                before=registry.read_bytes();bootstrap.install_runtime(source);bootstrap.install_runtime(source)
                self.assertEqual(registry.read_bytes(),before)
                self.assertEqual(history.read_text(),'private history')
                self.assertEqual((destination/'runtime-backups/manager.py.previous').read_text(),'old runtime')
