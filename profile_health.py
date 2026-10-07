"""Read-only compatibility checks. Never changes a clone or profile data."""
import plistlib
import subprocess
from pathlib import Path
from safe_io import digest


def inspect_profile(profile, source=Path('/Applications/Claude.app'), verify_signature=False):
    issues=[]; app=Path(profile['bundle'])
    def issue(code, detail, blocking=True):
        issues.append({'profile':profile['id'],'code':code,'detail':detail,'blocking':blocking})
    try:
        info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
        if info.get('CFBundleExecutable')!='Claude' or info.get('CFBundleIdentifier')!=profile['bundleID']:
            issue('clone_layout_changed','Bundle identity/launcher changed; repair the clone.')
        for name in ('Claude','Claude.bin'):
            if not (app/'Contents/MacOS'/name).is_file(): issue('missing_binary',name+' is missing; repair the clone.')
        version=info.get('CFBundleShortVersionString','')
        if not profile.get('sourceVersion') or version!=profile['sourceVersion']:
            issue('clone_version_changed','Clone version differs from its recorded source; repair before sync.')
        shim=app/'Contents/MacOS/Claude'
        if profile.get('shimDigest') and shim.exists() and digest(shim.read_bytes())!=profile['shimDigest']:
            issue('launcher_modified','Launcher changed; repair before sync.')
        if verify_signature:
            checked=subprocess.run(['/usr/bin/codesign','--verify',str(app)],capture_output=True,timeout=15)
            if checked.returncode: issue('invalid_signature','Clone signature verification failed.')
    except (OSError,ValueError,plistlib.InvalidFileException,subprocess.TimeoutExpired) as e:
        issue('unreadable_clone',str(e))
    try:
        source_info=plistlib.loads((source/'Contents/Info.plist').read_bytes())
        if source_info.get('CFBundleShortVersionString')!=profile.get('sourceVersion'):
            issue('source_version_changed','Official Claude changed; use repair to rebuild this closed clone.',False)
    except (OSError,ValueError,plistlib.InvalidFileException):
        issue('source_unavailable','Official Claude not available for rebuilding.',False)
    return issues
