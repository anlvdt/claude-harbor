#!/usr/bin/env python3
"""Build the redistributable manager only, never Claude itself or user profiles."""
import argparse
import json
import plistlib
import shutil
import subprocess
import zipfile
from pathlib import Path

from verify_release import runtime_files, verify_release, write_checksum

SOURCE = Path(__file__).resolve().parent
VERSION = '0.3.0'
BUILD_VERSION = '3'


def package_zip(app, asset):
    with zipfile.ZipFile(asset, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for path in [app, *sorted(app.rglob('*'))]:
            archive.write(path, path.relative_to(app.parent))


def build(architecture='arm64', *, signing_identity=None, notary_profile=None):
    if architecture not in ('arm64', 'x86_64'):
        raise ValueError('Unsupported architecture: ' + architecture)
    if notary_profile and not signing_identity:
        raise ValueError('Notarization requires a Developer ID signing identity')
    if signing_identity == '-':
        raise ValueError('Omit signing identity for ad-hoc builds')
    out = SOURCE / 'dist'
    asset = out / ('Claude-Harbor-' + VERSION + '-macOS-' + architecture + '.zip')
    # Never leave an earlier asset/checksum looking like this invocation succeeded.
    asset.unlink(missing_ok=True)
    Path(str(asset) + '.sha256').unlink(missing_ok=True)
    app = out / 'Claude Harbor.app'
    if app.exists():
        shutil.rmtree(app)
    mac = app / 'Contents/MacOS'
    runtime = app / 'Contents/Resources/backend'
    mac.mkdir(parents=True)
    runtime.mkdir(parents=True)
    subprocess.run(['/usr/bin/swiftc', '-parse-as-library', '-target', architecture + '-apple-macos14.0',
                    str(SOURCE / 'AccountManager.swift'), str(SOURCE / 'HarborUI.swift'), str(SOURCE / 'AddProfileSheet.swift'), str(SOURCE / 'HistoryUI.swift'),
                    '-o', str(mac / 'ClaudeHarbor')], check=True)
    for name in runtime_files(SOURCE):
        shutil.copy2(SOURCE / name, runtime / name)
    info = {'CFBundleExecutable': 'ClaudeHarbor', 'CFBundleIdentifier': 'io.github.anlvdt.claudeharbor',
            'CFBundleName': 'Claude Harbor', 'CFBundleDisplayName': 'Claude Harbor',
            'CFBundleShortVersionString': VERSION, 'CFBundleVersion': BUILD_VERSION, 'CFBundlePackageType': 'APPL',
            'NSHighResolutionCapable': True, 'LSMinimumSystemVersion': '14.0',
            'CFBundleIconFile': 'AppIcon.icns'}
    shutil.copy2(SOURCE / 'assets/AppIcon.icns', app / 'Contents/Resources/AppIcon.icns')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    signing = ['/usr/bin/codesign', '--force', '--sign', signing_identity or '-']
    if signing_identity:
        signing += ['--options', 'runtime', '--timestamp']
    subprocess.run([*signing, str(app)], check=True)
    signature = 'developer-id' if signing_identity else 'ad-hoc'
    verify_release(app, source=SOURCE, version=VERSION, build_version=BUILD_VERSION,
                   signature=signature)
    # A temporary submission ZIP must never masquerade as the final release asset.
    if notary_profile:
        submission = out / ('notary-submission-' + architecture + '.zip')
        package_zip(app, submission)
        try:
            result = subprocess.run(['xcrun', 'notarytool', 'submit', str(submission),
                                     '--keychain-profile', notary_profile, '--wait',
                                     '--output-format', 'json'], check=True, capture_output=True, text=True)
            if json.loads(result.stdout).get('status') != 'Accepted':
                raise ValueError('Apple notarization was not Accepted')
            subprocess.run(['xcrun', 'stapler', 'staple', str(app)], check=True)
        finally:
            submission.unlink(missing_ok=True)
    candidate = out / (asset.name + '.candidate')
    try:
        package_zip(app, candidate)
        verify_release(app, source=SOURCE, version=VERSION, build_version=BUILD_VERSION,
                       zip_path=candidate, signature=signature, notarized=bool(notary_profile))
        candidate.replace(asset)
    finally:
        candidate.unlink(missing_ok=True)
    checksum = write_checksum(asset)
    print(checksum)
    print(asset)
    return app


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--arch', choices=('arm64', 'x86_64'), default='arm64')
    parser.add_argument('--signing-identity', help='Existing Developer ID Application identity in Keychain')
    parser.add_argument('--notary-profile', help='Existing notarytool Keychain profile; uploads to Apple')
    args = parser.parse_args()
    build(args.arch, signing_identity=args.signing_identity, notary_profile=args.notary_profile)
