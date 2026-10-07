# Changelog

## v0.2.0 — 2026-10-07

- Fix the JSON decode failure reported in [issue #1](https://github.com/anlvdt/claude-harbor/issues/1): malformed Desktop Code records are audited and their profiles are excluded from writes while healthy profiles continue.
- Include the file path and actual line/column in JSON/JSONL errors, including incomplete Claude Code transcript lines. Preserve damaged source files and refuse to reset corrupt sync lineage automatically.
- Clarify partial-sync warnings in the manager and retain the audit's explicit profile selection, durable recovery, clone health checks and runtime safety fixes.
- Preserve prior-session chains and tombstones, reconcile auxiliary-only changes, and reject ambiguous or changing sources.
- Add write-ahead journals, restartable rollback, launch leases and immutable backend runtime generations.
- Add the **Sync** profile checkbox, **Kiểm tra** health diagnostics and backend `doctor`, `repair`, `recover` and explicit external import commands.
- Drain backend stdout/stderr concurrently and enforce timeout/output limits.

**Upgrade:** existing profiles start with sync disabled. Select **Sync** on at least two initialized profiles. Older clones without recorded health metadata must be repaired while closed before sync; profile login and history are retained. See [upgrade instructions](docs/session-sync.md#upgrading-from-v010).

**Validation:** 94 Python tests pass, including a reproduction of `Unterminated string starting at: line 1 column 253`; Swift backend process tests and the signed arm64 app build pass. These checks use disposable fixtures, not the issue author's private history.

## v0.1.0 — 2026-10-04

First public experimental release of **Claude Harbor**.

- Native AppKit manager with independent Claude Desktop profiles and a menu-bar shortcut.
- Create profiles, open one/all apps, and synchronize ready profiles with one button.
- Preserve separate account logins, import readable old local Code history, and retain divergent conversation branches.
- Back up writes, roll back failed transactions, and audit unavailable/empty transcript records.
- Bundle Harbor's backend scripts for first-launch setup on another Mac; retain the original prototype's registry and login/session data.
- Include a narrowly scoped experimental Magpie local gateway preset.
- English/Vietnamese README and real application screenshots.

**Validation:** 18 automated tests pass. The three-profile original installation was verified with 3,146 session groups, zero incomplete managed groups and zero conversation-content mismatches.

**Release asset:** macOS 14+, Apple Silicon arm64. Ad-hoc signed; not notarized. Requires an installed official Claude Desktop plus Apple Command Line Tools/Python 3. No Claude binaries, account data or transcripts are redistributed.

**Limits:** local Code only; no web Chat/Cowork/cloud or multi-device/live shared-session sync; no coordinated clone updater; experimental Magpie remap rather than arbitrary provider configuration. Intel can be built from source but is not runtime-tested in this release.
