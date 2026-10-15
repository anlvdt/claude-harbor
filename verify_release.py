#!/usr/bin/env python3
"""Verify a redistributable app and optional ZIP without launching its backend."""
import argparse
import hashlib
import ast
import plistlib
import re
import stat
import struct
import subprocess
import zipfile
from pathlib import Path

SOURCE = Path(__file__).resolve().parent


def runtime_files(source=SOURCE):
    """Read the canonical bootstrap manifest without importing account modules."""
    tree = ast.parse((Path(source) / 'bootstrap.py').read_text())
    assignments = [node.value for node in tree.body if isinstance(node, ast.Assign)
                   and any(isinstance(target, ast.Name) and target.id == 'FILES'
                           for target in node.targets)]
    if len(assignments) != 1:
        raise ValueError('Expected one bootstrap.FILES manifest')
    names = ast.literal_eval(assignments[0])
    if (not isinstance(names, (tuple, list)) or not names
            or any(not isinstance(name, str) or not name or Path(name).name != name
                   or name in ('.', '..', 'bootstrap.py') for name in names)
            or len(set(names)) != len(names)):
        raise ValueError('Invalid bootstrap.FILES manifest')
    return ('bootstrap.py', *names)


def verify_release(app, *, source=SOURCE, version=None, build_version=None, zip_path=None, signature='ad-hoc', notarized=False, checksum_path=None):
    """Raise ValueError on release defects; codesign is required on the host."""
    if signature not in ('ad-hoc', 'developer-id'):
        raise ValueError('Invalid signature policy')
    if notarized and signature != 'developer-id':
        raise ValueError('Notarization requires Developer ID verification')
    app, source = Path(app), Path(source)
    if version is None:
        # Importing build is safe: its build operation is explicit.
        from build import VERSION
        version = VERSION
    if build_version is None:
        from build import BUILD_VERSION
        build_version = BUILD_VERSION
    runtime = runtime_files(source)
    required = {'Contents/Info.plist', 'Contents/MacOS/ClaudeHarbor',
                'Contents/Resources/AppIcon.icns', 'Contents/_CodeSignature/CodeResources'}
    required.update('Contents/Resources/backend/' + name for name in runtime)
    # Stapled tickets are an allowed resource only in the notarized verification mode.
    if notarized and (app / 'Contents/CodeResources').exists():
        required.add('Contents/CodeResources')
    allowed_dirs = {str(parent) for name in required for parent in Path(name).parents
                    if str(parent) != '.'}
    if app.is_symlink() or not app.is_dir():
        raise ValueError('Missing app directory or symlink app')
    actual = set()
    for path in app.rglob('*'):
        name = path.relative_to(app).as_posix()
        if path.is_symlink():
            raise ValueError('Symlink in bundle: ' + name)
        if path.is_dir():
            if name not in allowed_dirs:
                raise ValueError('Unexpected directory: ' + name)
        elif path.is_file():
            actual.add(name)
        else:
            raise ValueError('Unexpected special file: ' + name)
    if actual - required:
        raise ValueError('Unexpected bundle files: ' + ', '.join(sorted(actual - required)))
    if required - actual:
        raise ValueError('Missing bundle files: ' + ', '.join(sorted(required - actual)))
    for name in runtime:
        if (app / 'Contents/Resources/backend' / name).read_bytes() != (source / name).read_bytes():
            raise ValueError('Runtime differs from source: ' + name)
    try:
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    except (ValueError, plistlib.InvalidFileException) as error:
        raise ValueError('Invalid Info.plist') from error
    expected = dict(CFBundleExecutable='ClaudeHarbor', CFBundleIdentifier='io.github.anlvdt.claudeharbor',
                    CFBundleName='Claude Harbor', CFBundleDisplayName='Claude Harbor',
                    CFBundleShortVersionString=version, CFBundleVersion=build_version, CFBundlePackageType='APPL',
                    CFBundleIconFile='AppIcon.icns', LSMinimumSystemVersion='14.0',
                    NSHighResolutionCapable=True)
    if not isinstance(info, dict):
        raise ValueError('Invalid Info.plist dictionary')
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError('Invalid Info.plist ' + key)
    if not isinstance(info.get('CFBundleVersion'), str) or not re.fullmatch(r'\d+(?:\.\d+){0,2}', info['CFBundleVersion']):
        raise ValueError('Invalid Info.plist CFBundleVersion')
    if not re.fullmatch(r'\d+\.\d+\.\d+', str(version)):
        raise ValueError('Invalid release version')
    executable = app / 'Contents/MacOS/ClaudeHarbor'
    if not executable.stat().st_mode & 0o111:
        raise ValueError('Executable lacks execute permission')
    binary = executable.read_bytes()
    if len(binary) < 28 or binary[:4] not in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'):
        raise ValueError('Executable is not Mach-O')
    icon = (app / 'Contents/Resources/AppIcon.icns').read_bytes()
    if len(icon) < 8 or icon[:4] != b'icns' or struct.unpack('>I', icon[4:8])[0] != len(icon):
        raise ValueError('Invalid icon ICNS header/length')
    try:
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)],
                       check=True, capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError('Signature verification failed: ' + str(getattr(error, 'stderr', '') or error)) from error
    details = subprocess.run(['/usr/bin/codesign', '--display', '--verbose=4', str(app)],
                             check=True, capture_output=True, text=True)
    description = details.stderr or ''
    if signature == 'ad-hoc':
        if 'Signature=adhoc' not in description:
            raise ValueError('Expected ad-hoc signature')
    else:
        if (not re.search(r'^Authority=Developer ID Application:', description, re.M)
                or not re.search(r'^TeamIdentifier=[A-Z0-9]{10}$', description, re.M)
                or not re.search(r'^Timestamp=.+', description, re.M)
                or not re.search(r'flags=.*\bruntime\b', description)):
            raise ValueError('Expected timestamped Developer ID signature with hardened runtime')
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R',
                        'anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists',
                        str(app)], check=True, capture_output=True)
    if notarized:
        subprocess.run(['xcrun', 'stapler', 'validate', str(app)], check=True, capture_output=True)
        subprocess.run(['/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=2', str(app)],
                       check=True, capture_output=True)
    # The manager needs no entitlements. Clone entitlements are a separate,
    # byte-verified runtime resource and must never be applied to Harbor itself.
    try:
        entitlements = subprocess.run(['/usr/bin/codesign', '--display', '--entitlements', '-', str(app)],
                                      check=True, capture_output=True).stdout
        if entitlements and plistlib.loads(entitlements) != {}:
            raise ValueError('Unexpected manager entitlements')
    except (OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        raise ValueError('Cannot verify manager entitlements') from error
    if zip_path is not None:
        verify_zip(app, zip_path)
    if checksum_path is not None:
        if zip_path is None:
            raise ValueError('Checksum requires ZIP')
        verify_checksum(zip_path, checksum_path)
    return app


def verify_zip(app, zip_path):
    """Require identical paths, bytes, file types and Unix permissions."""
    paths = [app, *app.rglob('*')]
    expected = {path.relative_to(app.parent).as_posix() + ('/' if path.is_dir() else ''): path
                for path in paths}
    try:
        with zipfile.ZipFile(zip_path) as archive:
            entries = archive.infolist()
            names = [entry.filename for entry in entries]
            if len(names) != len(set(names)) or set(names) != set(expected):
                raise ValueError('ZIP entries differ from bundle (extra, missing or duplicate)')
            for entry in entries:
                path = expected[entry.filename]
                mode = entry.external_attr >> 16
                if stat.S_IFMT(mode) != stat.S_IFMT(path.stat().st_mode) or stat.S_IMODE(mode) != stat.S_IMODE(path.stat().st_mode):
                    raise ValueError('ZIP file type/permissions differ: ' + entry.filename)
                if not path.is_dir() and archive.read(entry) != path.read_bytes():
                    raise ValueError('ZIP bytes differ: ' + entry.filename)
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        raise ValueError('ZIP verification failed: ' + str(error)) from error


def checksum_line(asset):
    asset = Path(asset)
    with asset.open('rb') as stream:
        digest = hashlib.sha256(stream.read()).hexdigest()
    return f'{digest}  {asset.name}\n'


def write_checksum(asset):
    path = Path(str(asset) + '.sha256')
    path.write_text(checksum_line(asset))
    return path


def verify_checksum(asset, checksum):
    if Path(checksum).read_text() != checksum_line(asset):
        raise ValueError('SHA256 checksum differs from release ZIP')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--zip', dest='zip_path', type=Path)
    parser.add_argument('--source', type=Path, default=SOURCE)
    parser.add_argument('--version')
    parser.add_argument('--signature', choices=('ad-hoc', 'developer-id'), default='ad-hoc')
    parser.add_argument('--notarized', action='store_true')
    parser.add_argument('--checksum', type=Path)
    args = parser.parse_args()
    try:
        verify_release(args.app, source=args.source, version=args.version, zip_path=args.zip_path, signature=args.signature,
                       notarized=args.notarized, checksum_path=args.checksum)
    except (ValueError, OSError, SyntaxError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Release verification failed: {error}\n')
    print(f'Verified {args.app}' + (f' and {args.zip_path}' if args.zip_path else ''))


if __name__ == '__main__':
    main()
