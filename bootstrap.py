"""Publish immutable backend generations; select a complete version atomically."""
import fcntl
import hashlib
import json
import os
import shutil
from pathlib import Path
import profile_store as store
from safe_io import atomic_write, private_dir, fsync_dir

FILES=('profile_store.py','manager.py','desktop_launcher.py','desktop_sync.py','history_inventory.py',
       'safe_io.py','sync_transaction.py','profile_health.py','verify_coverage.py','clone-entitlements.plist')

DISPATCH = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(__file__).resolve().parent
selected = json.loads((root/'current-runtime.json').read_text())['generation']
if len(selected) != 64 or any(c not in '0123456789abcdef' for c in selected):
    raise SystemExit('Invalid runtime generation')
script = root/'runtimes'/selected/Path(__file__).name
os.execv(sys.executable, [sys.executable, str(script), *sys.argv[1:]])
'''


def install_runtime(source):
    private_dir(store.ROOT)
    with (store.ROOT/'runtime.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        # Validate/read the WHOLE bundle before publishing anything.
        payloads = {name:(source/name).read_bytes() for name in FILES}
        generation = hashlib.sha256(b''.join(name.encode()+b'\0'+payloads[name] for name in FILES)).hexdigest()
        directory = store.ROOT/'runtimes'/generation
        private_dir(directory)
        for name, payload in payloads.items():
            target=directory/name
            if target.exists() and target.read_bytes()!=payload: raise ValueError('Runtime generation modified')
            if not target.exists(): atomic_write(target,payload)
        pointer=store.ROOT/'current-runtime.json'
        changed = not pointer.exists() or json.loads(pointer.read_text()).get('generation') != generation
        backup=store.ROOT/'runtime-backups'; private_dir(backup)
        if pointer.exists() and changed: atomic_write(backup/'previous-runtime.json',pointer.read_bytes())
        # Legacy entrypoints are backed up, never login/history data.
        for name in ('manager.py','desktop_launcher.py'):
            target=store.ROOT/name
            if target.exists() and target.read_text()!=DISPATCH:
                atomic_write(backup/(name+'.previous'),target.read_bytes())
        atomic_write(pointer, (json.dumps({'generation':generation})+'\n').encode())
        for name in ('manager.py','desktop_launcher.py'):
            atomic_write(store.ROOT/name, DISPATCH.encode())
        if not store.REGISTRY.exists(): store.save([])
    return store.ROOT

if __name__=='__main__': print(install_runtime(Path(__file__).parent))
