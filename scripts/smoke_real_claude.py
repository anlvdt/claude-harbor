#!/usr/bin/env python3
"""Opt-in headless clone smoke test. Uses a disposable HOME, never real accounts.
Run: python3 scripts/smoke_real_claude.py
Requires macOS, /Applications/Claude.app and the Xcode command line tools.
Never launches Electron: a synthetic HOME can trigger macOS Keychain prompts.
GUI launch, login/OAuth and authenticated Code require manual acceptance.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

SOURCE = Path(__file__).resolve().parents[1]


def child():
    sys.path.insert(0, str(SOURCE))
    import bootstrap
    import manager
    import profile_store as store
    assert store.ROOT.is_relative_to(Path(os.environ['HOME']))
    bootstrap.install_runtime(SOURCE)
    profiles = [manager.create('Harbor Smoke ' + str(i), 'claude') for i in (1, 2)]
    assert manager.doctor()['ok']
    p = profiles[0]
    for i, profile in enumerate(profiles):
        account, org = str(uuid.uuid4()), str(uuid.uuid4())
        gui = store.gui(profile)
        (gui/'config.json').write_text(json.dumps({'lastKnownAccountUuid': account}))
        records = gui/'claude-code-sessions'/account/org
        records.mkdir(parents=True, exist_ok=True)
        if i == 0:
            sid, local = str(uuid.uuid4()), 'local_' + str(uuid.uuid4())
            rows = [
                {'type':'user','uuid':str(uuid.uuid4()),'sessionId':sid,'cwd':'/harbor-smoke','timestamp':'2026-10-15T01:00:00Z','message':{'role':'user','content':'Disposable smoke fixture'}},
                {'type':'assistant','uuid':str(uuid.uuid4()),'sessionId':sid,'timestamp':'2026-10-15T01:00:01Z','message':{'role':'assistant','content':[{'type':'text','text':'Fixture response'}],'stop_reason':'end_turn'}},
                {'type':'system','subtype':'stop_hook_summary','timestamp':'2026-10-15T01:00:02Z'}]
            transcript = store.ROOT/'profiles'/profile['id']/'code/projects/-harbor-smoke'/ (sid+'.jsonl')
            transcript.parent.mkdir(parents=True, exist_ok=True)
            transcript.write_text(''.join(json.dumps(r)+'\n' for r in rows))
            (records/(local+'.json')).write_text(json.dumps({'sessionId':local,'cliSessionId':sid,'title':'Harbor smoke fixture','cwd':'/harbor-smoke','model':'sonnet','lastAssistantUuid':rows[1]['uuid'],'completedTurns':1}))
        manager.select_profile(profile['id'], True)
    check = manager.dispatch(['check'])
    assert not check['busy'] and not check['running']
    report = manager.dispatch(['sync'])
    assert report['profiles'] == 2 and report['sessions'] == 1
    verification = manager.dispatch(['verify'])
    assert verification['sessionGroups'] == 1
    assert manager.dispatch(['sync'])['filesChanged'] == 0
    # Simulate a changed launcher; rebuilding must preserve history and identity.
    before = {str(f.relative_to(store.ROOT)): f.read_bytes() for f in (store.ROOT/'profiles').rglob('*.jsonl')}
    shim = Path(p['bundle'])/'Contents/MacOS/Claude'
    with shim.open('ab') as handle: handle.write(b'harbor-smoke-change')
    assert any(i['code'] == 'launcher_modified' for i in manager.doctor()['issues'])
    rebuilt = manager.repair(p['id'])
    assert rebuilt['id'] == p['id'] and manager.doctor()['ok']
    assert all((store.ROOT/name).read_bytes() == data for name, data in before.items())
    manager.dispatch(['verify'])
    print(json.dumps({'realCloneCreate':True, 'fixtureSyncAndVerify':True,
                      'idempotentSync':True, 'realCloneRepairPreservesHistory':True,
                      'guiLaunchTested':False, 'authenticatedLoginTested':False}))


if __name__ == '__main__':
    if '--child' in sys.argv:
        child()
    else:
        with tempfile.TemporaryDirectory(prefix='harbor-real-smoke-') as home:
            result = subprocess.run([sys.executable, str(Path(__file__).resolve()), '--child'],
                                    env={**os.environ, 'HOME':home}, text=True, capture_output=True, timeout=240)
            if result.returncode:
                sys.stderr.write(result.stderr)
                raise SystemExit(result.returncode)
            print(result.stdout.strip())
