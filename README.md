# Claude Harbor

**Multiple Claude accounts. One place to launch them and sync local Code sessions.**

Claude Harbor is a small native macOS app that creates independent copies of your installed Claude Desktop, keeps each account's login separate, and synchronizes local Claude Code history between explicitly selected ready profiles with one click.

[Download v0.2.0](https://github.com/anlvdt/claude-harbor/releases/tag/v0.2.0) · [Tiếng Việt](README.vi.md) · [How sync works](docs/session-sync.md)

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

## Scope of v0.2.0

**Supported:** readable **local Code sessions on the same Mac** from explicitly selected profiles, including conversation transcripts, Desktop session records, previous session chains and relevant per-session files when copying history. Profile credentials and target permissions stay separate. Harbor checks clone health before writes and can repair a closed stale clone while retaining its profile data.

**Not supported:** Claude web Chat history, Cowork, cloud sessions, cross-device sync, live simultaneous writes to one shared session, or automatic restoration of deleted/unavailable transcripts. Profiles must briefly close during sync. After a Claude Desktop update, use **Kiểm tra** and repair each affected closed clone deliberately.

The optional Magpie profile preset targets the tested local gateway at `http://127.0.0.1:3425` and its Desktop model remap. It is experimental and is **not** a general provider/model configuration UI. Keep Magpie running and verify the gateway's own routing before relying on a particular model. See [sync details](docs/session-sync.md).

## Validation

The original three-account installation was checked against **3,146 session groups**: all three profiles had every managed group, with **zero conversation-content mismatches**. This is a measured local result, not a guarantee that unavailable source transcripts can be restored.

Automated tests cover three/four-profile fan-out, idempotence, conversation updates, divergent branches, write refusal while apps are running, rollback, multiple organizations, importing orphan transcripts and pending profile initialization. See [release notes](CHANGELOG.md).

## Build from source

Requires Python 3, Swift and Apple Command Line Tools. No third-party Python packages or Node.js are required.

```sh
git clone https://github.com/anlvdt/claude-harbor.git
cd claude-harbor
python3 -m unittest discover -s . -p 'test*.py'
python3 build.py                 # dist/Claude Harbor.app + arm64 ZIP
python3 install.py               # build + install into ~/Applications
```

`python3 build.py --arch x86_64` builds an Intel target; Intel runtime behavior has not been verified in this release.

## Local data and implementation

The app bundles its own Python runtime scripts, not Python itself. At first launch it installs these scripts in its Application Support directory. Profile registry: `profiles.json`; private profile data: `profiles/<id>/gui` or `gui-3p`, and `profiles/<id>/code`.

Sync produces `last-sync.json`, `history-audit.json`, `sync-state.json` and write-ahead transaction journals/backups in `sync-backups/`. The backend publishes immutable runtime generations and switches them through `current-runtime.json`, so a partial runtime update is not selected. No account credentials, local histories or backups are included in this repository or the release.

The launcher preserves the internal bundle name `Claude` so Electron finds its helpers, gives each clone a distinct bundle ID and data directory, and keeps the vendor-signed frameworks. The official app stays untouched. Clone executables and outer bundles are re-signed locally with the included entitlements.

## Inspiration and license

Implementation research referenced [ai-profiles](https://github.com/bartekczyz/ai-profiles), [Magpie](https://github.com/yetone/magpie) and [Claude Code Desktop documentation](https://code.claude.com/docs/en/desktop). Harbor is an independent community utility, not an Anthropic product.

Harbor's source is [MIT licensed](LICENSE). Claude Desktop and third-party services remain subject to their own licenses and terms.
