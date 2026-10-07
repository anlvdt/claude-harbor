#!/usr/bin/env python3
"""Launch isolated Claude Desktop bundles with fully separate local state."""
import json
import fcntl
import os
import time
from pathlib import Path
import sys
import profile_store as store
import sync_transaction
import profile_health

ROOT = store.ROOT


def environment(profile):
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(('ANTHROPIC_', 'CLAUDE_CODE_USE_')) or key in (
            'CLAUDE_CONFIG_DIR', 'CLAUDE_SECURESTORAGE_CONFIG_DIR',
            'CLAUDE_USER_DATA_DIR', 'CLAUDE_CODE_OAUTH_TOKEN',
            'CLAUDE_CODE_HOST_CREDS_FILE', 'CLAUDE_CODE_HOST_GATEWAY_LINEAGE',
            'CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST', 'CLAUDE_CODE_SUBAGENT_MODEL',
            'CLAUDE_CODE_PROJECT_DIR_NAME', 'CLAUDE_CODE_SESSION_ACCESS_TOKEN',
        ):
            env.pop(key, None)
    base = ROOT / 'profiles' / profile
    env['CLAUDE_CONFIG_DIR'] = str(base / 'code')
    p = next(p for p in store.load() if p['id'] == profile)
    legacy = p.get('legacyAccount')
    if legacy:
        desktop = store.gui(p) / 'config.json'
        cli = Path.home() / '.config/magpie/claude-accounts' / legacy / '.claude.json'
        current = json.loads(desktop.read_text()).get('lastKnownAccountUuid') if desktop.exists() else None
        old = json.loads(cli.read_text()).get('oauthAccount', {}).get('accountUuid') if cli.exists() else None
        if current and current != old: legacy = None
    env['CLAUDE_SECURESTORAGE_CONFIG_DIR'] = str(Path.home() / '.config/magpie/claude-accounts' / legacy if legacy else base / 'code')
    if next(p for p in store.load() if p['id'] == profile)['kind'] == 'magpie':
        # Desktop's inference profile supplies gateway credentials/model.
        # Do not force raw model IDs from CLI into Desktop's mapped catalog.
        env['ANTHROPIC_BASE_URL'] = 'http://127.0.0.1:3425'
        env['ANTHROPIC_API_KEY'] = 'magpie-claude-desktop'
    return env


def prepare_lease(lock):
    fcntl.flock(lock, fcntl.LOCK_SH)
    os.set_inheritable(lock.fileno(), True)


def keep_lease_until_exit(lock):
    # A child retains the shared lock across the parent's exec and Electron startup.
    # Keeping LaunchServices' original PID preserves Dock/termination behavior.
    parent = os.getpid()
    child = os.fork()
    if child == 0:
        try:
            while os.getppid() == parent:
                time.sleep(0.1)
        finally:
            os._exit(0)
    os.set_inheritable(lock.fileno(), False)


def main():
    profile, bundle = sys.argv[1:3]
    selected=next((p for p in store.load() if p['id']==profile),None)
    if selected is None or Path(bundle)!=Path(selected['bundle']):
        raise SystemExit('Unknown desktop profile or bundle')
    # Wait while the one-click synchronizer is updating profile state.
    # A keeper holds this lease until the launched app exits, even during exec.
    sync_lock = (ROOT / 'sync.lock').open('a')
    prepare_lease(sync_lock)
    if sync_transaction.pending(ROOT):
        raise SystemExit('Incomplete sync: close profiles and run manager.py recover before launching.')
    repair=ROOT/'clone-repair.json'
    if repair.exists() and json.loads(repair.read_text()).get('state')=='active':
        raise SystemExit('Incomplete clone repair: run manager.py repair for the affected profile.')
    issues=[i for i in profile_health.inspect_profile(selected) if i['blocking']]
    if issues: raise SystemExit(issues[0]['detail'])
    binary = Path(bundle) / 'Contents/MacOS/Claude.bin'
    env = environment(profile)
    log_path = ROOT / 'profiles' / profile / 'startup.log'
    fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.dup2(fd, 1)
    os.dup2(fd, 2)
    os.close(fd)
    # Preserve arguments delivered to the profile by LaunchServices.
    args = [str(binary), '--user-data-dir=' + str(ROOT / 'profiles' / profile / 'gui'), *sys.argv[3:]]
    keep_lease_until_exit(sync_lock)
    os.execve(str(binary), args, env)


if __name__ == '__main__':
    main()
