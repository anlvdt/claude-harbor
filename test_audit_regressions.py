"""Data-integrity regressions; all inputs live in disposable fixture roots."""
import copy
import json
import os
import types
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch
import test_desktop_sync as fixture

sync = fixture.sync

class IntegrityTests(fixture.SyncTests):
    def test_issue_1_truncated_desktop_record_preserves_data_and_reports_file(self):
        bad = sync.account_dir('pro1') / ('local_' + str(uuid.uuid4()) + '.json')
        bad.parent.mkdir(parents=True)
        payload = '{"padding":"' + 'x' * 230 + '","title":"unfinished'
        with self.assertRaisesRegex(json.JSONDecodeError, 'Unterminated string.*column 253'):
            json.loads(payload)
        bad.write_text(payload)
        report = sync.sync_all()
        self.assertEqual(report['sessions'], 1)
        self.assertEqual(bad.read_text(), payload)
        self.assertEqual({p for p, _, _ in sync.records()}, {'pro2', 'magpie'})
        audit = json.loads((sync.ROOT / 'history-audit.json').read_text())
        warning = next(w for w in audit['warnings'] if w.get('record') == str(bad))
        self.assertIn(str(bad), warning['detail'])
        self.assertIn('line 1', warning['detail'])

    def test_issue_1_truncated_code_transcript_reports_actual_line_without_salvage(self):
        with self.file.open('a') as f:
            f.write('{"type":"assistant","message":{"content":"unfinished')
        original = self.file.read_bytes()
        report = sync.sync_all()
        self.assertEqual(report['sessions'], 0)
        self.assertEqual(self.file.read_bytes(), original)
        self.assertEqual({p for p, _, _ in sync.records()}, {'magpie'})
        audit = json.loads((sync.ROOT / 'history-audit.json').read_text())
        warning = next(w for w in audit['warnings'] if w.get('reason') == 'cannot_load_history')
        self.assertIn(str(self.file), warning['detail'])
        self.assertIn('line 4', warning['detail'])

    def test_issue_1_corrupt_manifest_fails_with_file_context_without_reset(self):
        state = sync.ROOT / 'sync-state.json'
        payload = b'{"members":{"private-session":"unfinished'
        state.write_bytes(payload)
        with self.assertRaisesRegex(ValueError, 'sync-state.json.*line 1'):
            sync.sync_all()
        self.assertEqual(state.read_bytes(), payload)
        self.assertEqual({p for p, _, _ in sync.records()}, {'magpie'})

    def test_tombstone_is_not_rediscovered(self):
        (self.record.parent / ('deleted_' + self.local[6:])).touch()
        sync.sync_all()
        self.assertEqual(sync.records(), [])

    def test_deleted_member_is_not_recreated_from_other_profiles(self):
        sync.sync_all()
        member = self.member('pro1')
        (member['path'].parent / ('deleted_' + member['path'].stem[6:])).touch()
        sync.sync_all()
        self.assertFalse(any(p == 'pro1' for p, _, _ in sync.records()))

    def test_prior_chain_survives_self_copy_and_reverse_updates(self):
        prior = str(uuid.uuid4())
        prior_file = self.file.with_name(prior + '.jsonl')
        prior_rows = copy.deepcopy(self.rows)
        for row in prior_rows:
            if 'sessionId' in row: row['sessionId'] = prior
        prior_file.write_text('\n'.join(map(json.dumps, prior_rows)) + '\n')
        self.rows = []
        self.turn(self.rows, self.d, 'two', self.cli)
        self.d['priorCliSessionIds'] = [prior]
        self.write(self.file, self.record, self.rows, self.d)
        sync.sync_all()
        self.assertEqual(len(sync.records()), len(sync.NAMES))
        for p in sync.NAMES: self.assertEqual(len(self.member(p)['signature']), 4)
        self.assertEqual(sync.sync_all()['filesChanged'], 0)
        member = self.member('pro1'); d = member['record']
        f, rows = member['files'][d['cliSessionId']]
        self.turn(rows, d, 'three', d['cliSessionId'])
        self.write(f, member['path'], rows, d)
        sync.sync_all()
        for p in sync.NAMES: self.assertEqual(len(self.member(p)['signature']), 6)
        self.assertEqual(sync.sync_all()['filesChanged'], 0)

    def test_auxiliary_only_change_and_missing_target_are_reconciled(self):
        aux = sync.code('magpie') / 'tasks' / self.cli / 'task.txt'
        aux.parent.mkdir(parents=True); aux.write_text('before')
        sync.sync_all()
        aux.write_text('after')
        sync.sync_all()
        sid = self.member('pro1')['record']['cliSessionId']
        target = sync.code('pro1') / 'tasks' / sid / 'task.txt'
        self.assertEqual(target.read_text(), 'after')
        target.unlink(); sync.sync_all()
        self.assertEqual(target.read_text(), 'after')

    def test_equal_metadata_different_content_is_not_cached_as_equal(self):
        inv = sync.inventory
        inv.PATH_CACHE.clear(); inv.SUMMARIES.clear()
        other = sync.code('pro1') / 'projects/-test' / self.file.name
        other.parent.mkdir(parents=True); other.write_bytes(self.file.read_bytes().replace(b'one', b'two'))
        stamp = self.file.stat(); os.utime(other, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        a = inv.summarize(self.file)['signature']
        b = inv.summarize(other)['signature']
        self.assertNotEqual(a, b)
        other.write_bytes(self.file.read_bytes()); os.utime(other, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        self.assertEqual(inv.summarize(other)['signature'], a)

    def test_unbound_external_root_is_not_imported(self):
        external = sync.ROOT / 'external'; f = external / 'projects/-test' / self.file.name
        f.parent.mkdir(parents=True); self.file.rename(f); self.record.unlink()
        sync.HISTORY_ROOTS = [external]
        sync.sync_all()
        self.assertEqual(sync.records(), [])

    def test_malformed_profile_is_blocked_without_aborting_healthy_groups(self):
        bad = sync.account_dir('pro1') / ('local_' + str(uuid.uuid4()) + '.json')
        bad.parent.mkdir(parents=True); bad.write_text('{')
        report = sync.sync_all()
        self.assertGreater(report['warnings'], 0)
        self.assertEqual({p for p, _, _ in sync.records()}, {'pro2', 'magpie'})
        self.assertEqual(bad.read_text(), '{')

    def test_snapshot_does_not_copy_late_source_mutation(self):
        source = sync.snapshot('magpie', self.record, self.d)
        self.file.write_text(self.file.read_text().replace('one', 'two'))
        tx = sync.Transaction()
        with self.assertRaisesRegex(ValueError, 'changed|thay đổi'):
            sync.copy_session(source, 'pro1', None, str(uuid.uuid4()), tx)
        self.assertFalse(sync.account_dir('pro1').exists())

    def test_duplicate_sid_with_different_contents_is_rejected(self):
        other = self.file.parent.parent / 'other' / self.file.name
        other.parent.mkdir(); other.write_bytes(self.file.read_bytes().replace(b'one', b'two'))
        sync.inventory.TRANSCRIPTS.clear()
        with self.assertRaisesRegex(ValueError, 'Ambiguous|ambiguous'):
            sync.transcript('magpie', self.cli)

    def test_symlink_auxiliary_cannot_copy_outside_source(self):
        secret = sync.ROOT / 'unrelated'; secret.write_text('dummy-secret')
        folder = sync.code('magpie') / 'tasks' / self.cli
        folder.mkdir(parents=True); (folder / 'escape').symlink_to(secret)
        report = sync.sync_all()
        self.assertGreater(report['warnings'], 0)
        for p in ('pro1', 'pro2'):
            self.assertEqual(list((sync.code(p)/'tasks').glob('*/escape')), [])

class RecoveryTests(fixture.SyncTests):
    def test_abandoned_transaction_recovers_old_and_new_files(self):
        existing = sync.ROOT / 'existing'; existing.write_bytes(b'old')
        created = sync.ROOT / 'new'
        tx = sync.Transaction(); tx.write(existing, b'new'); tx.write(created, b'created')
        # Simulates loss of all in-memory transaction state, without commit/rollback.
        self.assertTrue((tx.root / 'journal.json').exists())
        sync.recover_transactions()
        self.assertEqual(existing.read_bytes(), b'old')
        self.assertFalse(created.exists())
        sync.recover_transactions()
        self.assertEqual(existing.read_bytes(), b'old')

    def test_private_transaction_files(self):
        tx = sync.Transaction(); target = sync.ROOT / 'private' / 'history.jsonl'
        tx.write(target, b'private')
        self.assertEqual(target.stat().st_mode & 0o777, 0o600)
        self.assertEqual(target.parent.stat().st_mode & 0o777, 0o700)

    def test_committed_transaction_is_not_rolled_back(self):
        target = sync.ROOT / 'value'; target.write_bytes(b'old')
        tx = sync.Transaction(); tx.write(target, b'new'); tx.commit()
        sync.recover_transactions()
        self.assertEqual(target.read_bytes(), b'new')

class BoundaryTests(fixture.SyncTests):
    def test_external_binding_survives_later_sync_without_external_root(self):
        external=sync.ROOT/'external'; f=external/'projects/-test'/self.file.name
        f.parent.mkdir(parents=True); self.file.rename(f); self.record.unlink()
        sync.HISTORY_ROOTS=[external]; sync.EXTERNAL_TARGETS={str(external):['pro1','pro2']}
        sync.sync_all()
        sync.HISTORY_ROOTS=[]; sync.EXTERNAL_TARGETS={}
        sync.sync_all()
        self.assertEqual({p for p,_,_ in sync.records()}, {'pro1','pro2'})

    def test_tombstone_without_retained_record_does_not_resurrect_group(self):
        sync.sync_all(); member=self.member('pro1')
        (member['path'].parent/('deleted_'+member['path'].stem[6:])).touch()
        member['path'].unlink()
        sync.sync_all()
        self.assertFalse(any(p=='pro1' for p,_,_ in sync.records()))

    def test_unreadable_member_does_not_get_duplicate_replacement(self):
        sync.sync_all(); member=self.member('pro1')
        member['files'][member['record']['cliSessionId']][0].write_text('{')
        before=set(sync.account_dir('pro1').glob('local_*.json'))
        report=sync.sync_all()
        self.assertGreater(report['warnings'],0)
        self.assertEqual(set(sync.account_dir('pro1').glob('local_*.json')),before)

    def test_recovery_after_repeated_writes_is_idempotent(self):
        target=sync.ROOT/'value'; target.write_bytes(b'old')
        tx=sync.Transaction(); tx.write(target,b'first'); tx.write(target,b'second')
        # First recovery restored the initial bytes but died before its state marker.
        from safe_io import atomic_write
        atomic_write(target,b'old')
        sync.recover_transactions()
        self.assertEqual(target.read_bytes(),b'old')

    def test_verifier_ignores_stale_summary_and_detects_auxiliary_damage(self):
        sync.sync_all()
        import verify_coverage
        self.assertTrue(hasattr(verify_coverage,'verify'))
        self.assertEqual(verify_coverage.verify(sync)['conversationMismatches'],[])
        member=self.member('pro1'); path=member['files'][member['record']['cliSessionId']][0]
        stat=path.stat(); path.write_bytes(path.read_bytes().replace(b'one',b'two'))
        os.utime(path,ns=(stat.st_atime_ns,stat.st_mtime_ns))
        self.assertTrue(verify_coverage.verify(sync)['conversationMismatches'])

    def test_record_change_after_capture_aborts_without_overwriting_it(self):
        original=sync.copy_session; changed=[]
        def race(source,profile,existing,gid,tx):
            if not changed:
                changed.append(True)
                self.record.write_text(json.dumps({**self.d,'title':'concurrent-change'}))
            return original(source,profile,existing,gid,tx)
        with patch.object(sync,'copy_session',side_effect=race):
            with self.assertRaisesRegex(ValueError,'changed'):
                sync.sync_all()
        self.assertEqual(json.loads(self.record.read_text())['title'],'concurrent-change')

class ReviewRegressions(fixture.SyncTests):
    def test_auxiliary_edit_survives_conversation_append_elsewhere(self):
        aux=sync.code('magpie')/'tasks'/self.cli/'task.txt'; aux.parent.mkdir(parents=True); aux.write_text('baseline')
        sync.sync_all(); aux.write_text('local-edit')
        m=self.member('pro1'); d=m['record']; file,rows=m['files'][d['cliSessionId']]
        self.turn(rows,d,'two',d['cliSessionId']); self.write(file,m['path'],rows,d)
        sync.sync_all()
        self.assertEqual(aux.read_text(),'local-edit')
        for p in sync.NAMES:
            sid=self.member(p)['record']['cliSessionId']
            self.assertEqual((sync.code(p)/'tasks'/sid/'task.txt').read_text(),'local-edit')

    def test_equal_conversation_retains_target_system_rows(self):
        sync.sync_all()
        row={'type':'system','uuid':str(uuid.uuid4()),'subtype':'local-only','content':'keep-me'}
        with self.file.open('a') as f: f.write(json.dumps(row)+'\n')
        sync.sync_all()
        self.assertIn(row,[json.loads(l) for l in self.file.read_text().splitlines()])

    def test_temporary_failure_does_not_revoke_external_targets(self):
        external=sync.ROOT/'external'; f=external/'projects/-test'/self.file.name
        f.parent.mkdir(parents=True); self.file.rename(f); self.record.unlink()
        sync.HISTORY_ROOTS=[external]; sync.EXTERNAL_TARGETS={str(external):['pro1','pro2']}
        bad=sync.account_dir('pro2')/('local_'+str(uuid.uuid4())+'.json'); bad.parent.mkdir(parents=True); bad.write_text('{')
        sync.sync_all(); bad.unlink(); sync.HISTORY_ROOTS=[]; sync.EXTERNAL_TARGETS={}
        sync.sync_all()
        self.assertEqual({p for p,_,_ in sync.records()},{'pro1','pro2'})

    def test_verifier_detects_entire_missing_group(self):
        import verify_coverage
        sync.sync_all()
        for _,path,_ in sync.records(): path.unlink()
        result=verify_coverage.verify(sync)
        self.assertTrue(result['missingTranscripts'] or result['incompleteGroups'])

    def test_external_desktop_prior_chain_stays_one_session(self):
        external=sync.ROOT/'external'; desktop=sync.ROOT/'desktop'
        prior=str(uuid.uuid4()); prior_file=external/'projects/-test'/(prior+'.jsonl')
        prior_file.parent.mkdir(parents=True); prior_file.write_bytes(self.file.read_bytes())
        self.rows=[]; self.turn(self.rows,self.d,'two',self.cli)
        self.d['priorCliSessionIds']=[prior]
        target=external/'projects/-test'/self.file.name
        record=desktop/'claude-code-sessions/account/org'/self.record.name
        self.write(target,record,self.rows,self.d); self.record.unlink(); self.file.unlink()
        sync.HISTORY_ROOTS=[external]; sync.DESKTOP_ROOTS=[desktop]; sync.EXTERNAL_TARGETS={str(external):list(sync.NAMES)}
        sync.sync_all()
        self.assertEqual(len(sync.records()),len(sync.NAMES))
        for p in sync.NAMES: self.assertEqual(len(self.member(p)['signature']),4)

    def test_equal_conversation_preserves_different_chain_layout(self):
        self.turn(self.rows,self.d,'two',self.cli)
        self.write(self.file,self.record,self.rows,self.d)
        sync.sync_all()
        prior=str(uuid.uuid4())
        self.file.with_name(prior+'.jsonl').write_text('\n'.join(map(json.dumps,self.rows[:2]))+'\n')
        self.d=json.loads(self.record.read_text()); self.d['priorCliSessionIds']=[prior]
        self.write(self.file,self.record,self.rows[2:],self.d)
        before=self.member('magpie')['signature']
        sync.sync_all()
        self.assertEqual(self.member('magpie')['signature'],before)
        self.assertEqual(self.member('magpie')['record']['priorCliSessionIds'],[prior])

    def test_invalid_allowed_targets_isolates_profile(self):
        sync.sync_all()
        m=self.member('pro1'); d=m['record']; d['threeAppSync']['allowedTargets']=17
        m['path'].write_text(json.dumps(d))
        report=sync.sync_all()
        self.assertGreater(report['warnings'],0)
        self.assertNotIn('pro1',{p for p,_,_ in sync.records()})
