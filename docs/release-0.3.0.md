# Claude Harbor 0.3.0 release guide

Status: source release candidate, version **0.3.0**, bundle build **3**. Nothing in this preparation publishes a GitHub release or dispatches CI. The existing public download remains v0.2.0.

## Release notes ready for publication

Claude Harbor 0.3.0 improves the native account manager with a resizable interface, light/dark appearance, accessible account controls, keyboard shortcuts and an account-creation form that retains input on errors. Profile health and deliberate repair/recovery actions make sync readiness clearer. A versioned desktop/backend protocol provides structured failures; operation state is shared with the menu bar, and history is verified before apps reopen after sync.

Native **Nhập lịch sử…** lets you select a Code configuration directory containing `projects`, optionally choose matching Desktop metadata, and confirm import into selected ready profiles. **Xác minh lịch sử** checks consistency independently. **Báo cáo & hoạt động** shows recent results and opens reports/backups. Import/verification require at least one selected ready profile, closed Claude clones and no blocking health/recovery state. The bounded activity log stores timestamps, operation categories, outcomes and counts; detailed backend reports can contain private paths/session identifiers.

The release adds macOS CI, installed-runtime Swift tests, strict bundle/ZIP verification and SHA256 checksums. Harbor distributes its manager and backend scripts only. Claude Desktop, profile credentials and transcripts are never release assets.

Upgrade: quit Harbor, replace only Claude Harbor.app, and reopen it. The existing Application Support directory, profile logins and history remain. Existing prototype installations retain `ClaudeThreeDesktop`; newer ones use `ClaudeHarbor`. Health-check profiles after a Claude update and repair closed stale clones as needed. Select sync participants explicitly.

Scope remains local Code sessions on one Mac. Web Chat, Cowork, cloud/cross-device sync and live shared-session writes are outside this release. Intel can be compiled but its runtime has not been validated.

## Build and verify the default candidate

Use macOS 14+, Apple Command Line Tools, Swift and Python 3. No third-party Python packages are needed. Run from the repo root:

```sh
python3 -m unittest discover -s . -p 'test*.py'
swiftc -D BACKEND_TEST -parse-as-library AccountManager.swift HarborUI.swift AddProfileSheet.swift HistoryUI.swift tests/BackendProcessTests.swift -o /tmp/HarborBackendTests
/tmp/HarborBackendTests
swiftc -D BACKEND_TEST -parse-as-library AccountManager.swift HarborUI.swift AddProfileSheet.swift HistoryUI.swift tests/AddProfileSheetTests.swift -o /tmp/HarborSheetTests
/tmp/HarborSheetTests
python3 build.py --arch arm64
python3 verify_release.py 'dist/Claude Harbor.app' --zip dist/Claude-Harbor-0.3.0-macOS-arm64.zip --checksum dist/Claude-Harbor-0.3.0-macOS-arm64.zip.sha256
(cd dist && shasum -a 256 -c Claude-Harbor-0.3.0-macOS-arm64.zip.sha256)
```

Assets: `dist/Claude-Harbor-0.3.0-macOS-arm64.zip` and its `.zip.sha256` sidecar. The checksum covers the final ZIP bytes. It detects changes but does not authenticate the publisher. Verification checks exact manifest/source bytes, absence of private/extra files, metadata, Mach-O executable, ICNS, signature policy, entitlements and ZIP bytes/types/permissions. Default builds require an ad-hoc signature and make no Gatekeeper acceptance claim.

## Optional Developer ID and notarization

The host must already contain a usable **Developer ID Application** identity/private key and, for notarization, an existing **notarytool Keychain profile**. Scripts never import certificates, accept passwords/API keys, create credentials, or print secrets. Check identities read-only with `security find-identity -v -p codesigning`; choose the existing profile name in Keychain Access. No profile name or identity is assumed.

Signing only (substitute the existing identity name or SHA-1):

```sh
python3 build.py --signing-identity 'Developer ID Application: YOUR EXISTING IDENTITY'
python3 verify_release.py 'dist/Claude Harbor.app' --signature developer-id --zip dist/Claude-Harbor-0.3.0-macOS-arm64.zip --checksum dist/Claude-Harbor-0.3.0-macOS-arm64.zip.sha256
```

The signing flow uses hardened runtime and a secure timestamp. Verification requires the Apple Developer ID certificate requirement, team identifier, timestamp and runtime flag. Harbor receives no entitlements; the clone entitlement file remains a backend resource.

The following command **uploads the manager ZIP to Apple**. Run only when that external submission is authorized:

```sh
python3 build.py --signing-identity 'Developer ID Application: YOUR EXISTING IDENTITY' --notary-profile 'YOUR EXISTING PROFILE'
python3 verify_release.py 'dist/Claude Harbor.app' --signature developer-id --notarized --zip dist/Claude-Harbor-0.3.0-macOS-arm64.zip --checksum dist/Claude-Harbor-0.3.0-macOS-arm64.zip.sha256
```

It waits for `Accepted`, staples the app, rebuilds the final ZIP, validates the ticket and Gatekeeper assessment, then writes its checksum. Signing alone does not mean notarized. A rejected/failed submission stops the build. For failed submissions, retrieve Apple's log separately using the returned submission ID and the same existing profile. See Apple's [notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) and [custom workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Headless smoke with real Claude bundles

```sh
python3 scripts/smoke_real_claude.py
```

The revised harness is **headless only**: it creates and signs actual disposable Claude clones, runs doctor, synchronizes/verifies fixture history, then corrupts and repairs a launcher while checking that fixture history remains unchanged. It never launches Electron. This revised check passed: real bundle creation, fixture sync/verify, idempotence, and repaired-clone history preservation. It does not test GUI behavior.

An earlier GUI attempt used a temporary HOME and triggered a **Keychain Not Found / Claude Key** modal. Stopping the disposable process resolved the modal, and the main worker confirmed normal real-Claude behavior. That attempt is not a GUI acceptance pass. GUI launch, authenticated login, live Code replies and reopening after repair remain manual acceptance checks. Never launch Electron with a temporary HOME; the headless test provides no evidence for those GUI behaviors.

Read-only inspection by the main worker found three real profiles ready, zero selected, and `clone_version_changed` for all three. Per the user's instruction, keep the selection unchanged and update only Harbor locally. Do not repair, launch, synchronize or otherwise change these real profiles during release preparation. Their stale clone status is separate from manager packaging checks.

## Install and publish checklist

1. For the candidate, extract the verified ZIP and move Claude Harbor.app into `/Applications` or `~/Applications`. Install official Claude Desktop at `/Applications/Claude.app` first. Ad-hoc downloads may require explicit macOS approval; use System Settings → Privacy & Security → Open Anyway if offered after the blocked launch. Do not describe an ad-hoc artifact as Apple notarized.
2. Check clean installation and upgrade on a disposable macOS account; open the manager, add/open profiles, inspect history and verify sync/repair/recovery behavior. Test real signed/notarized downloads separately if those artifacts become available.
3. Inspect the successful macOS CI run for the exact final commit. CI stores ZIP/checksum artifacts for 14 days and never publishes or uses signing secrets. Download the candidate and verify its checksum after transfer.
4. After maintainer approval, tag the reviewed commit `v0.3.0` and create the GitHub release externally. Attach only the verified architecture ZIP and matching SHA256 sidecar. Use the release notes above, add exact measured validation and state **ad-hoc**, **Developer ID signed only**, or **notarized**, according to the actual asset. Update both README download links only once the release exists.

## Validation record and limits

On 2026-10-15, read-only local inspection found **0 valid code-signing identities** and no matching notarytool profile metadata in the accessible Keychain. No Apple submission was made. Developer ID/notary command paths can be checked with synthetic tests, but that does not validate real credentials, Apple's service or Gatekeeper acceptance. No new real-account sync or fresh-machine installation is claimed by this release preparation. Intel runtime and downloaded-app quarantine behavior remain untested. Local results: **135 Python tests passed**, including **21 release tests**; Swift backend/process/protocol and add-account-sheet executables passed; arm64 0.3.0/build 3 ad-hoc app, exact ZIP verification and independent SHA256 verification passed. After the UI worker updated HistoryUI.swift, the latest arm64 build and both Swift test suites passed without compiler warnings. The final build and installed app were independently verified. Harbor 0.3.0 was installed at `~/Applications/Claude Harbor.app`; the previous bundle is retained under `~/Library/Application Support/ClaudeHarborAppBackups/20261015-152816/`. Native UI inspection confirmed that startup loads three existing profiles, opens/closes the report viewer, and restores its controls. Registry bytes and all sync selections are unchanged; the installed runtime matches the source manifest. These results do not claim a GUI smoke pass; the main worker reports that the remote currently contains zero workflows, so dispatch is unavailable until the new workflow is pushed. Push, CI dispatch and public release remain the final external approval step; no remote success is claimed.

Import source admission checks reject visible Claude sessions referring to the source or its sessions, open writable file descriptors, and failed/timeout source inspection. Checks run before writes and before commit; snapshot validation still detects changed bytes. Third-party writers do not share Harbor locks: users must keep the source closed or use an offline copy. Post-sync verification failure leaves previously closed clones closed. Saved verification reports decode structured record errors and display counts without exposing their contents in the activity log.
