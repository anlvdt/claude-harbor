import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import manager
import profile_store as store
import bootstrap

class RuntimeSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for obj, name, value in [(store, 'ROOT', self.root), (store, 'REGISTRY', self.root/'profiles.json'),
                                 (manager, 'ROOT', self.root)]:
            p = patch.object(obj, name, value); p.start(); self.addCleanup(p.stop)

    def test_corrupt_report_does_not_hide_profiles(self):
        store.save([]); (self.root/'last-sync.json').write_text('{')
        result = manager.status()
        self.assertEqual(result['profiles'], [])
        self.assertIsNone(result['lastSync'])
        self.assertTrue(result['pending'])

    def test_unselected_profile_is_not_sync_eligible(self):
        p = dict(id='ptest', name='Test', kind='claude', bundle='/tmp/Test.app', bundleID='test', model='sonnet')
        store.save([p])
        with patch.object(store, 'account', return_value=self.root/'account/org'):
            manager.configure()
            self.assertEqual(manager.sync.NAMES, {})

    def test_duplicate_registry_identity_is_rejected(self):
        (self.root/'profiles.json').write_text(json.dumps({'version':1, 'profiles':[{'id':'same'},{'id':'same'}]}))
        with self.assertRaises(ValueError): store.load()

    def test_failed_runtime_staging_keeps_previous_generation(self):
        source = self.root/'bundle'; source.mkdir()
        for name in bootstrap.FILES: (source/name).write_text('first '+name)
        bootstrap.install_runtime(source)
        # Generation selection must survive an incomplete new bundle.
        pointer = self.root/'current-runtime.json'
        self.assertTrue(pointer.exists())
        before = pointer.read_bytes()
        for name in bootstrap.FILES: (source/name).write_text('second '+name)
        (source/bootstrap.FILES[-1]).unlink()
        with self.assertRaises(OSError): bootstrap.install_runtime(source)
        self.assertEqual(pointer.read_bytes(), before)

    def test_process_lease_survives_exec_and_blocks_sync(self):
        import desktop_launcher
        lock_path = self.root/'sync.lock'
        # Test uses a dummy child, never Claude. An inherited shared fd excludes writes.
        with lock_path.open('a') as lock:
            self.assertTrue(hasattr(desktop_launcher, 'prepare_lease'))
            desktop_launcher.prepare_lease(lock)
            child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(2)'], pass_fds=(lock.fileno(),))
        try:
            import fcntl
            with lock_path.open('a') as contender:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally: child.terminate(); child.wait(timeout=5)

if __name__ == '__main__': unittest.main()

class HealthTests(unittest.TestCase):
    def test_updated_clone_is_blocked_until_repaired(self):
        import plistlib
        import profile_health
        with tempfile.TemporaryDirectory() as temp:
            app=Path(temp)/'Claude.app'; mac=app/'Contents/MacOS'; mac.mkdir(parents=True)
            (mac/'Claude').write_bytes(b'shim'); (mac/'Claude.bin').write_bytes(b'vendor')
            info={'CFBundleExecutable':'Claude','CFBundleIdentifier':'test.profile','CFBundleShortVersionString':'2'}
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            p={'id':'ptest','bundle':str(app),'bundleID':'test.profile','sourceVersion':'1'}
            issues=profile_health.inspect_profile(p,source=Path(temp)/'missing')
            self.assertTrue(any(i['blocking'] and i['code']=='clone_version_changed' for i in issues))

    def test_source_update_is_reported_without_breaking_pinned_clone(self):
        import plistlib
        import profile_health
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); app=root/'Clone.app'; source=root/'Source.app'
            mac=app/'Contents/MacOS'; mac.mkdir(parents=True); (source/'Contents').mkdir(parents=True)
            for name in ('Claude','Claude.bin'): (mac/name).write_bytes(b'code')
            (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Claude','CFBundleIdentifier':'profile','CFBundleShortVersionString':'1'}))
            (source/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString':'2'}))
            p={'id':'ptest','bundle':str(app),'bundleID':'profile','sourceVersion':'1'}
            issues=profile_health.inspect_profile(p,source=source)
            self.assertTrue(any(i['code']=='source_version_changed' for i in issues))
            self.assertFalse(any(i['blocking'] for i in issues))

class CloneRepairTests(RuntimeSafetyTests):
    def test_repair_preserves_login_and_rolls_back_failed_registration(self):
        import plistlib
        import shutil
        source=self.root/'Source.app'; mac=source/'Contents/MacOS'; mac.mkdir(parents=True)
        (mac/'Claude').write_bytes(b'vendor')
        (source/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Claude','CFBundleShortVersionString':'2'}))
        target=self.root/'Existing.app'; target.mkdir(); (target/'old').write_bytes(b'previous clone')
        p=dict(id='ptest',name='Claude Test',kind='claude',bundle=str(target),bundleID='test.profile',model='sonnet',sourceVersion='1',syncEnabled=True)
        store.save([p]); private=self.root/'profiles/ptest/code/login'; private.parent.mkdir(parents=True); private.write_bytes(b'dummy-login')
        def native(args,**kwargs):
            if args[0]=='/bin/cp': shutil.copytree(args[-2],args[-1])
            elif args[0]=='/usr/bin/clang': Path(args[-1]).write_bytes(b'shim')
            return subprocess.CompletedProcess(args,0,b'',b'')
        original_save=store.save; failures=[]
        def fail_once(profiles):
            if not failures:
                failures.append(True); raise OSError('injected registry failure')
            return original_save(profiles)
        with patch.object(manager,'SOURCE',source),patch.object(Path,'home',return_value=self.root),patch.object(manager,'running',return_value=[]),patch.object(manager.subprocess,'run',side_effect=native),patch.object(store,'save',side_effect=fail_once):
            with self.assertRaisesRegex(OSError,'injected'): manager.repair('ptest')
        self.assertEqual((target/'old').read_bytes(),b'previous clone')
        self.assertEqual(private.read_bytes(),b'dummy-login')
        self.assertEqual(store.load()[0]['sourceVersion'],'1')

    def test_launch_is_blocked_by_uncommitted_journal(self):
        import sync_transaction
        tx=sync_transaction.Transaction(self.root); tx.write(self.root/'value',b'dummy')
        self.assertTrue(sync_transaction.pending(self.root))
        tx.rollback()
        self.assertFalse(sync_transaction.pending(self.root))

    def test_interrupted_runtime_entrypoints_are_repaired_on_next_install(self):
        source=self.root/'bundle'; source.mkdir()
        for name in bootstrap.FILES: (source/name).write_text('payload '+name)
        bootstrap.install_runtime(source)
        (self.root/'manager.py').unlink()
        bootstrap.install_runtime(source)
        self.assertTrue((self.root/'manager.py').is_file())

class CrashProcessTests(unittest.TestCase):
    def test_new_process_recovers_after_writer_exits_without_cleanup(self):
        import sync_transaction
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); (root/'existing').write_bytes(b'before')
            code="import os,sys; from pathlib import Path; from sync_transaction import Transaction; r=Path(sys.argv[1]); t=Transaction(r); t.write(r/'existing',b'after'); t.write(r/'new',b'created'); os._exit(9)"
            result=subprocess.run([sys.executable,'-c',code,temp],cwd=Path(__file__).parent,timeout=10)
            self.assertEqual(result.returncode,9)
            sync_transaction.recover(root)
            self.assertEqual((root/'existing').read_bytes(),b'before')
            self.assertFalse((root/'new').exists())

    def test_guard_refuses_to_overwrite_concurrent_destination(self):
        import sync_transaction
        from safe_io import digest
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); target=root/'value'; target.write_bytes(b'old')
            tx=sync_transaction.Transaction(root); tx.guards[str(target)]=digest(b'old')
            target.write_bytes(b'concurrent')
            with self.assertRaisesRegex(ValueError,'changed'): tx.write(target,b'replacement')
            self.assertEqual(target.read_bytes(),b'concurrent')

class InstalledRuntimeTests(unittest.TestCase):
    def test_real_generation_dispatch_runs_with_an_empty_home(self):
        import bootstrap
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            env={'HOME':temp,'PATH':'/usr/bin:/bin','TMPDIR':temp,'PYTHONDONTWRITEBYTECODE':'1'}
            subprocess.run([sys.executable,str(Path(bootstrap.__file__).resolve())],env=env,check=True,capture_output=True,timeout=10)
            entry=root/'Library/Application Support/ClaudeHarbor/manager.py'
            result=subprocess.run([sys.executable,str(entry),'status'],env=env,check=True,capture_output=True,timeout=10)
            self.assertEqual(json.loads(result.stdout)['profiles'],[])

    def test_keeper_retains_lease_when_exec_closes_the_launcher_fd(self):
        import fcntl
        import time
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp); ready=root/'ready'
            inner="from pathlib import Path; import sys,time; Path(sys.argv[1]).write_text('ready'); time.sleep(10)"
            outer="import os,sys; from pathlib import Path; import desktop_launcher as d; lock=(Path(sys.argv[1])/'sync.lock').open('a'); d.prepare_lease(lock); d.keep_lease_until_exit(lock); os.execv(sys.executable,[sys.executable,'-c',sys.argv[2],str(Path(sys.argv[1])/'ready')])"
            child=subprocess.Popen([sys.executable,'-c',outer,temp,inner],cwd=Path(__file__).parent)
            try:
                deadline=time.monotonic()+5
                while not ready.exists() and time.monotonic()<deadline: time.sleep(.01)
                self.assertTrue(ready.exists())
                with (root/'sync.lock').open('a') as lock:
                    with self.assertRaises(BlockingIOError): fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
                    child.terminate(); child.wait(timeout=5)
                    deadline=time.monotonic()+3
                    while True:
                        try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB); break
                        except BlockingIOError:
                            if time.monotonic()>deadline: self.fail('Lease leaked after parent exit')
                            time.sleep(.01)
            finally:
                if child.poll() is None: child.terminate(); child.wait(timeout=5)
