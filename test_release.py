"""Release checks use synthetic bundles only; no account data is accessed."""
import plistlib
import struct
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import build


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        (self.source / 'bootstrap.py').write_text("FILES=('manager.py', 'backend_protocol.py')\nraise RuntimeError('must not execute')\n")
        for name in ('manager.py', 'backend_protocol.py'):
            (self.source / name).write_text('# synthetic runtime\n')
        self.app = self.root / 'Claude Harbor.app'
        self.contents = self.app / 'Contents'
        self.backend = self.contents / 'Resources/backend'
        self.backend.mkdir(parents=True)
        for name in ('bootstrap.py', 'manager.py', 'backend_protocol.py'):
            (self.backend / name).write_bytes((self.source / name).read_bytes())
        self.executable = self.contents / 'MacOS/ClaudeHarbor'
        self.executable.parent.mkdir()
        self.executable.write_bytes(b'\xcf\xfa\xed\xfe' + b'\0' * 28)
        self.executable.chmod(0o755)
        self.icon = self.contents / 'Resources/AppIcon.icns'
        self.icon.write_bytes(b'icns' + struct.pack('>I', 8))
        self.info = dict(CFBundleExecutable='ClaudeHarbor', CFBundleIdentifier='io.github.anlvdt.claudeharbor', CFBundleName='Claude Harbor', CFBundleDisplayName='Claude Harbor', CFBundleShortVersionString=build.VERSION, CFBundleVersion=build.BUILD_VERSION, CFBundlePackageType='APPL', CFBundleIconFile='AppIcon.icns', LSMinimumSystemVersion='14.0', NSHighResolutionCapable=True)
        self.write_plist()
        signature = self.contents / '_CodeSignature/CodeResources'
        signature.parent.mkdir()
        signature.write_bytes(b'synthetic signature')

    def write_plist(self):
        (self.contents / 'Info.plist').write_bytes(plistlib.dumps(self.info))

    def verify(self, **kwargs):
        import verify_release
        with patch('verify_release.subprocess.run', return_value=subprocess.CompletedProcess([], 0, stderr='Signature=adhoc\n')):
            return verify_release.verify_release(self.app, source=self.source, version=build.VERSION, **kwargs)

    def test_accepts_complete_bundle_without_executing_bootstrap(self):
        self.verify()

    def test_requires_every_manifest_file_and_bootstrap(self):
        for name in ('bootstrap.py', 'manager.py', 'backend_protocol.py'):
            with self.subTest(name=name):
                target = self.backend / name
                payload = target.read_bytes()
                target.unlink()
                with self.assertRaisesRegex(ValueError, 'Missing'):
                    self.verify()
                target.write_bytes(payload)

    def test_rejects_unexpected_files_anywhere(self):
        for name in ('Contents/Resources/backend/accounts.json', 'Contents/Resources/profiles/token', 'Contents/MacOS/Claude'):
            with self.subTest(name=name):
                target = self.app / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text('synthetic private data')
                with self.assertRaisesRegex(ValueError, 'Unexpected'):
                    self.verify()
                target.unlink()
                if target.parent.name == 'profiles':
                    target.parent.rmdir()

    def test_rejects_modified_runtime(self):
        (self.backend / 'manager.py').write_text('# stale runtime')
        with self.assertRaisesRegex(ValueError, 'Runtime'):
            self.verify()

    def test_rejects_symlinks(self):
        target = self.backend / 'manager.py'
        target.unlink()
        target.symlink_to(self.source / 'manager.py')
        with self.assertRaisesRegex(ValueError, '[Ss]ymlink'):
            self.verify()

    def test_rejects_bad_metadata(self):
        for key, value in (('CFBundleShortVersionString', '0.1.0'), ('CFBundleVersion', ''), ('CFBundleVersion', '999'), ('CFBundleExecutable', '../evil'), ('CFBundleIdentifier', 'other'), ('CFBundlePackageType', 'BNDL'), ('CFBundleIconFile', 'missing.icns'), ('LSMinimumSystemVersion', 'bad')):
            with self.subTest(key=key):
                original = self.info[key]
                self.info[key] = value
                self.write_plist()
                with self.assertRaises(ValueError):
                    self.verify()
                self.info[key] = original
                self.write_plist()

    def test_rejects_invalid_executable_or_icon(self):
        self.executable.chmod(0o644)
        with self.assertRaisesRegex(ValueError, '[Ee]xecutable'):
            self.verify()
        self.executable.chmod(0o755)
        self.executable.write_bytes(b'not Mach-O')
        with self.assertRaisesRegex(ValueError, 'Mach-O'):
            self.verify()
        self.executable.write_bytes(b'\xcf\xfa\xed\xfe' + b'\0' * 28)
        self.icon.write_bytes(b'invalid')
        with self.assertRaisesRegex(ValueError, '[Ii]con'):
            self.verify()

    def test_requires_icon_executable_plist_and_signature(self):
        for relative in ('Resources/AppIcon.icns', 'MacOS/ClaudeHarbor', 'Info.plist', '_CodeSignature/CodeResources'):
            with self.subTest(relative=relative):
                path = self.contents / relative
                data, mode = path.read_bytes(), path.stat().st_mode
                path.unlink()
                with self.assertRaisesRegex(ValueError, 'Missing'):
                    self.verify()
                path.write_bytes(data)
                path.chmod(mode)

    def test_rejects_invalid_plist(self):
        (self.contents / 'Info.plist').write_bytes(b'broken')
        with self.assertRaisesRegex(ValueError, 'Info.plist'):
            self.verify()

    def test_rejects_unsafe_manifest_paths(self):
        for manifest in ("('../private.json',)", "('/tmp/private.json',)", "('manager.py', 'manager.py')"):
            with self.subTest(manifest=manifest):
                (self.source / 'bootstrap.py').write_text('FILES=' + manifest)
                with self.assertRaisesRegex(ValueError, 'manifest'):
                    self.verify()

    def test_rejects_failed_signature(self):
        import verify_release
        with patch('verify_release.subprocess.run', side_effect=subprocess.CalledProcessError(1, 'codesign')):
            with self.assertRaisesRegex(ValueError, '[Ss]ignature'):
                verify_release.verify_release(self.app, source=self.source, version=build.VERSION)

    def test_rejects_unexpected_manager_entitlements(self):
        import verify_release
        with patch('verify_release.subprocess.run', return_value=subprocess.CompletedProcess([], 0, stderr='Signature=adhoc\n', stdout=plistlib.dumps({'com.apple.security.get-task-allow': True}))):
            with self.assertRaisesRegex(ValueError, '[Ee]ntitlements'):
                verify_release.verify_release(self.app, source=self.source, version=build.VERSION)

    def make_zip(self):
        archive = self.root / 'release.zip'
        with zipfile.ZipFile(archive, 'w') as output:
            for path in [self.app, *sorted(self.app.rglob('*'))]:
                output.write(path, path.relative_to(self.app.parent))
        return archive

    def fake_build(self, *, signing_identity=None, notary_profile=None, notary_status='Accepted'):
        assets = self.source / 'assets'
        assets.mkdir()
        (assets / 'AppIcon.icns').write_bytes(self.icon.read_bytes())

        commands = []
        def run_command(command, **kwargs):
            commands.append(command)
            if command[0] == '/usr/bin/swiftc':
                self.assertIn(str(self.source / 'HistoryUI.swift'), command)
                executable = Path(command[command.index('-o') + 1])
                executable.write_bytes(self.executable.read_bytes())
                executable.chmod(0o755)
            elif command[:2] == ['/usr/bin/codesign', '--force']:
                signature = Path(command[-1]) / 'Contents/_CodeSignature/CodeResources'
                signature.parent.mkdir()
                signature.write_bytes(b'synthetic signature')
            elif command[:3] == ['xcrun', 'notarytool', 'submit']:
                self.assertIn('--keychain-profile', command)
                self.assertEqual(command[command.index('--keychain-profile') + 1], notary_profile)
                return subprocess.CompletedProcess(command, 0, stdout='{"status": "' + notary_status + '"}')
            elif command[:2] == ['/usr/bin/codesign', '--display'] and signing_identity:
                return subprocess.CompletedProcess(command, 0, stdout=b'', stderr=
                    'Authority=Developer ID Application: Test\nTeamIdentifier=ABCDEFGHIJ\nTimestamp=Today\nflags=0x10000(runtime)\n')
            elif command[:2] not in (['/usr/bin/codesign', '--verify'], ['/usr/bin/codesign', '--display'], ['xcrun', 'stapler'], ['/usr/sbin/spctl', '--assess']):
                self.fail('Unexpected external command: ' + repr(command))
            return subprocess.CompletedProcess(command, 0, stderr='Signature=adhoc\n')

        with patch.object(build, 'SOURCE', self.source), patch('subprocess.run', side_effect=run_command):
            app = build.build(signing_identity=signing_identity, notary_profile=notary_profile)
            archive = self.source / 'dist' / ('Claude-Harbor-' + build.VERSION + '-macOS-arm64.zip')
            import verify_release
            verify_release.verify_release(app, source=self.source, version=build.VERSION, zip_path=archive,
                                          signature='developer-id' if signing_identity else 'ad-hoc',
                                          notarized=bool(notary_profile))
            self.assertEqual({path.name for path in (app / 'Contents/Resources/backend').iterdir()},
                             {'bootstrap.py', 'manager.py', 'backend_protocol.py'})

        return commands

    def test_build_uses_manifest_and_produces_verified_zip(self):
        commands = self.fake_build()
        self.assertFalse(any('notarytool' in c for c in commands))

    def test_build_signed_and_notarized_command_order(self):
        commands = self.fake_build(signing_identity='existing identity', notary_profile='existing profile')
        signing = next(c for c in commands if c[:2] == ['/usr/bin/codesign', '--force'])
        self.assertIn('--timestamp', signing)
        self.assertEqual(signing[signing.index('--options') + 1], 'runtime')
        submit = next(i for i,c in enumerate(commands) if c[:3] == ['xcrun', 'notarytool', 'submit'])
        staple = next(i for i,c in enumerate(commands) if c[:3] == ['xcrun', 'stapler', 'staple'])
        validate = next(i for i,c in enumerate(commands) if c[:3] == ['xcrun', 'stapler', 'validate'])
        self.assertLess(submit, staple)
        self.assertLess(staple, validate)
        self.assertFalse((self.source / 'dist/notary-submission-arm64.zip').exists())

    def test_failed_notarization_leaves_no_release_asset(self):
        with self.assertRaisesRegex(ValueError, 'not Accepted'):
            self.fake_build(signing_identity='existing identity', notary_profile='existing profile', notary_status='Invalid')
        self.assertFalse(list((self.source / 'dist').glob('*.zip')))
        self.assertFalse(list((self.source / 'dist').glob('*.sha256')))

    def test_checksum_detects_tampering(self):
        from verify_release import write_checksum, verify_checksum
        archive = self.make_zip()
        checksum = write_checksum(archive)
        verify_checksum(archive, checksum)
        archive.write_bytes(archive.read_bytes() + b'tampered')
        with self.assertRaisesRegex(ValueError, 'SHA256'):
            verify_checksum(archive, checksum)

    def test_notarization_requires_identity_before_build(self):
        with patch('subprocess.run') as run:
            with self.assertRaisesRegex(ValueError, 'requires'):
                build.build(notary_profile='existing-profile')
            run.assert_not_called()

    def test_developer_id_policy_and_notarization(self):
        from verify_release import verify_release
        details = ('Authority=Developer ID Application: Example (ABCDEFGHIJ)\n'
                   'TeamIdentifier=ABCDEFGHIJ\nTimestamp=Oct 15, 2026\nflags=0x10000(runtime)\n')
        def command(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, stdout=b'', stderr=details)
        with patch('verify_release.subprocess.run', side_effect=command) as run:
            verify_release(self.app, source=self.source, signature='developer-id', notarized=True)
            calls = [c.args[0] for c in run.call_args_list]
            self.assertTrue(any(c[:3] == ['xcrun', 'stapler', 'validate'] for c in calls))
            self.assertTrue(any(c[0] == '/usr/sbin/spctl' for c in calls))
            self.assertTrue(any('-R' in c for c in calls))
        for missing in ('Authority=', 'Timestamp=', 'TeamIdentifier=', 'flags='):
            incomplete = '\n'.join(line for line in details.splitlines() if not line.startswith(missing))
            with self.subTest(missing=missing), patch('verify_release.subprocess.run',
                    return_value=subprocess.CompletedProcess([], 0, stderr=incomplete)):
                with self.assertRaisesRegex(ValueError, 'Developer ID'):
                    verify_release(self.app, source=self.source, signature='developer-id')

    def test_ad_hoc_policy_rejects_other_signature(self):
        from verify_release import verify_release
        with patch('verify_release.subprocess.run', return_value=subprocess.CompletedProcess([], 0, stderr='Signature=other')):
            with self.assertRaisesRegex(ValueError, 'ad-hoc'):
                verify_release(self.app, source=self.source)

    def test_zip_matches_bundle(self):
        self.verify(zip_path=self.make_zip())

    def test_rejects_zip_extra_missing_modified_and_duplicate_entries(self):
        for mutation in ('extra', 'missing', 'modified', 'duplicate', 'permissions'):
            with self.subTest(mutation=mutation):
                archive = self.make_zip()
                with zipfile.ZipFile(archive) as original:
                    entries = [(i, original.read(i)) for i in original.infolist()]
                target = 'Claude Harbor.app/Contents/MacOS/ClaudeHarbor'
                with zipfile.ZipFile(archive, 'w') as output:
                    for info, data in entries:
                        if info.filename == target:
                            if mutation == 'missing':
                                continue
                            if mutation == 'modified':
                                data = b'changed'
                            if mutation == 'permissions':
                                info.external_attr = 0o100644 << 16
                        output.writestr(info, data)
                    if mutation == 'extra':
                        output.writestr('../private.json', 'synthetic')
                    if mutation == 'duplicate':
                        import warnings
                        with warnings.catch_warnings():
                            warnings.simplefilter('ignore', UserWarning)
                            output.writestr(target, b'duplicate')
                with self.assertRaisesRegex(ValueError, 'ZIP'):
                    self.verify(zip_path=archive)


if __name__ == '__main__':
    unittest.main()
