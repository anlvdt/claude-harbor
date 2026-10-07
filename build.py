#!/usr/bin/env python3
"""Build the redistributable manager only, never Claude itself or user profiles."""
import argparse, plistlib, shutil, subprocess
from pathlib import Path
SOURCE=Path(__file__).resolve().parent
VERSION='0.2.0'

def build(architecture='arm64'):
    out=SOURCE/'dist';app=out/'Claude Harbor.app'
    if app.exists():shutil.rmtree(app)
    mac=app/'Contents/MacOS';runtime=app/'Contents/Resources/backend'
    mac.mkdir(parents=True);runtime.mkdir(parents=True)
    subprocess.run(['/usr/bin/swiftc','-parse-as-library','-target',architecture+'-apple-macos14.0',str(SOURCE/'AccountManager.swift'),'-o',str(mac/'ClaudeHarbor')],check=True)
    for name in ('bootstrap.py','profile_store.py','manager.py','desktop_launcher.py','desktop_sync.py','history_inventory.py','safe_io.py','sync_transaction.py','profile_health.py','verify_coverage.py','clone-entitlements.plist'):
        shutil.copy2(SOURCE/name,runtime/name)
    info={'CFBundleExecutable':'ClaudeHarbor','CFBundleIdentifier':'io.github.anlvdt.claudeharbor','CFBundleName':'Claude Harbor','CFBundleDisplayName':'Claude Harbor','CFBundleShortVersionString':VERSION,'CFBundleVersion':'2','CFBundlePackageType':'APPL','NSHighResolutionCapable':True,'LSMinimumSystemVersion':'14.0'}
    icon=SOURCE/'assets/AppIcon.icns'
    if icon.exists():shutil.copy2(icon,app/'Contents/Resources/AppIcon.icns');info['CFBundleIconFile']='AppIcon.icns'
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(app)],check=True)
    subprocess.run(['/usr/bin/codesign','--verify',str(app)],check=True)
    asset=out/('Claude-Harbor-'+VERSION+'-macOS-'+architecture+'.zip')
    subprocess.run(['/usr/bin/ditto','-c','-k','--sequesterRsrc','--keepParent',str(app),str(asset)],check=True)
    print(asset);return app

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--arch',choices=('arm64','x86_64'),default='arm64');args=parser.parse_args();build(args.arch)
