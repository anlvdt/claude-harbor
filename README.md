# Claude Harbor

**Multiple Claude accounts. One place to launch them and sync local Code sessions.**

Claude Harbor is a small native macOS app that creates independent copies of your installed Claude Desktop, keeps each account's login separate, and synchronizes local Claude Code history between explicitly selected ready profiles with one click.

[Latest published release: v0.2.0](https://github.com/anlvdt/claude-harbor/releases/tag/v0.2.0) · [Tiếng Việt](README.vi.md) · [How sync works](docs/session-sync.md)

![Claude Harbor managing three independent profiles](docs/screenshots/claude-harbor-native.png)

## What you can do

- **Add accounts:** create another real Claude Desktop app and sign in there. No terminal UI.
- **Run them together:** open one profile or all profiles; each has its own Desktop and Code configuration.
- **Sync with one click:** choose the profiles in a sync group, wait for active replies, close the running profiles, back up and synchronize history, then reopen only the apps that were running.
- **Keep divergent conversations:** retain separate branches when accounts continue the same session differently.
- **Recover old local history:** discover transcripts that lack Desktop sidebar entries, including readable archived sessions.
- **Use the menu bar:** launch profiles or sync without keeping the manager window open.
- **Recover safely:** inspect reports and backups, recover an interrupted transaction before another write, and run health checks or repair a stale clone.

![Adding a separate Claude account](docs/screenshots/claude-harbor-add-profile.png)

## Install

The release provides an **Apple Silicon (arm64)** app for **macOS 14 or later**. Install [Claude Desktop](https://claude.com/download) in `/Applications/Claude.app` first. Harbor creates clones locally; it does not ship Claude's binaries.

1. Install Apple Command Line Tools if you do not already have them: `xcode-select --install`. Harbor uses `/usr/bin/python3` for its local backend and `clang`/`codesign` when creating profiles.
2. Download `Claude-Harbor-0.2.0-macOS-arm64.zip` from [Releases](https://github.com/anlvdt/claude-harbor/releases/tag/v0.2.0).
3. Extract it and move **Claude Harbor.app** into `/Applications` or `~/Applications`.
4. Open it, choose **+ Thêm tài khoản**, name a profile, then sign in within the new Claude window.
5. Open the **Code** tab, create a **Local** session, and click **Làm mới** in Harbor. After at least two profiles are ready, select **Sync** on the profiles that may share history, then click **Đồng bộ đã chọn**.

The interface is currently Vietnamese. The release is **ad-hoc signed, not Apple notarized**; macOS may require your explicit approval to open the downloaded app. Building from source is also supported.

Existing installations from the earlier local prototype are retained in `~/Library/Application Support/ClaudeThreeDesktop`. New installations use `~/Library/Application Support/ClaudeHarbor`.

## Scope of v0.3.0 source

**Supported:** readable **local Code sessions on the same Mac** from explicitly selected profiles, including conversation transcripts, Desktop session records, previous session chains and relevant per-session files when copying history. Profile credentials and target permissions stay separate. Harbor checks clone health before writes and can repair a closed stale clone while retaining its profile data.

**Not supported:** Claude web Chat history, Cowork, cloud sessions, cross-device sync, live simultaneous writes to one shared session, or automatic restoration of deleted/unavailable transcripts. Profiles must briefly close during sync. After a Claude Desktop update, use **Kiểm tra** and repair each affected closed clone deliberately.

The optional Magpie profile preset targets the tested local gateway at `http://127.0.0.1:3425` and its Desktop model remap. It is experimental and is **not** a general provider/model configuration UI. Keep Magpie running and verify the gateway's own routing before relying on a particular model. See [sync details](docs/session-sync.md).

## Validation

The 0.3.0 release candidate (build 3) adds per-profile clone health and **Sửa** actions, **Kiểm tra → Phục hồi**, shared window/menu-bar operation state, and fresh verification before reopening apps after sync. Desktop/backend calls use a versioned protocol with structured errors; ordinary CLI commands retain their JSON result format. Version 0.3.0 is prepared locally and has not been published. Use the source build below or the existing v0.2.0 download. See the [0.3.0 release guide](docs/release-0.3.0.md) for candidate assets, checksums, signing options and validation limits.

The updated native interface resizes with the window, follows macOS light/dark appearance, shows selected accounts and explains unavailable sync actions. The add-account sheet validates names inline and keeps inputs when creation fails. Keyboard shortcuts: ⌘N add, ⌘O open all, ⌘R refresh, ⌘I health checks and ⌘Return sync.

**Nhập lịch sử…** imports from a Code configuration folder containing `projects`, with optional Desktop metadata and explicit target confirmation. **Xác minh lịch sử** checks history separately; **Báo cáo & hoạt động** shows recent results and opens detailed reports/backups. Import/verification require selected ready profiles, closed clones and resolved blocking health/recovery issues. The activity log stores only timestamps, operation kinds, outcomes and counts; detailed reports may contain private identifiers and paths.

The original three-account installation was checked against **3,146 session groups**: all three profiles had every managed group, with **zero conversation-content mismatches**. This is a measured local result, not a guarantee that unavailable source transcripts can be restored.

Automated tests cover three/four-profile fan-out, idempotence, conversation updates, divergent branches, write refusal while apps are running, rollback, multiple organizations, importing orphan transcripts and pending profile initialization. See [release notes](CHANGELOG.md).

## Build from source

Requires Python 3, Swift and Apple Command Line Tools. No third-party Python packages or Node.js are required.

```sh
git clone https://github.com/anlvdt/claude-harbor.git
cd claude-harbor
python3 -m unittest discover -s . -p 'test*.py'
swiftc -D BACKEND_TEST -parse-as-library AccountManager.swift HarborUI.swift AddProfileSheet.swift HistoryUI.swift tests/BackendProcessTests.swift -o /tmp/HarborBackendTests
/tmp/HarborBackendTests
swiftc -D BACKEND_TEST -parse-as-library AccountManager.swift HarborUI.swift AddProfileSheet.swift HistoryUI.swift tests/AddProfileSheetTests.swift -o /tmp/HarborSheetTests
/tmp/HarborSheetTests
python3 build.py                 # ad-hoc app + arm64 ZIP + .zip.sha256
python3 verify_release.py 'dist/Claude Harbor.app' --zip dist/Claude-Harbor-0.3.0-macOS-arm64.zip --checksum dist/Claude-Harbor-0.3.0-macOS-arm64.zip.sha256
python3 install.py               # build + install into ~/Applications
```

`python3 build.py --arch x86_64` builds an Intel target; Intel runtime behavior has not been verified in this release.

The default build is ad-hoc signed. Optional Developer ID hardened-runtime signing and notarization use existing Keychain credentials only; see the [release guide](docs/release-0.3.0.md). Builds verify the runtime manifest and source bytes, bundle metadata, executable, icon, signature, and ZIP contents/permissions. macOS CI runs the Python suite, Swift process/protocol tests against an installed disposable runtime, and the verified build. Neither automated test flow signs into Claude or uses real profile history. The headless real-bundle smoke entry point is `python3 scripts/smoke_real_claude.py`: clone creation/signing/doctor and fixture sync/verification/repair, with no Electron launch. A prior temporary-HOME GUI attempt triggered a Keychain modal; stopping its process resolved it. GUI launch and reopening after repair remain manual acceptance checks. Authenticated login and live Code replies remain manual checks; see the [validation record](docs/release-0.3.0.md#validation-record-and-limits).

## Local data and implementation

The app bundles its own Python runtime scripts, not Python itself. At first launch it installs these scripts in its Application Support directory. Profile registry: `profiles.json`; private profile data: `profiles/<id>/gui` or `gui-3p`, and `profiles/<id>/code`.

Sync produces `last-sync.json`, `history-audit.json`, `sync-state.json` and write-ahead transaction journals/backups in `sync-backups/`. The backend publishes immutable runtime generations and switches them through `current-runtime.json`, so a partial runtime update is not selected. No account credentials, local histories or backups are included in this repository or the release.

The launcher preserves the internal bundle name `Claude` so Electron finds its helpers, gives each clone a distinct bundle ID and data directory, and keeps the vendor-signed frameworks. The official app stays untouched. Clone executables and outer bundles are re-signed locally with the included entitlements.

## Inspiration and license

Implementation research referenced [ai-profiles](https://github.com/bartekczyz/ai-profiles), [Magpie](https://github.com/yetone/magpie) and [Claude Code Desktop documentation](https://code.claude.com/docs/en/desktop). Harbor is an independent community utility, not an Anthropic product.

Harbor's source is [MIT licensed](LICENSE). Claude Desktop and third-party services remain subject to their own licenses and terms.
