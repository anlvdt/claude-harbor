# Changelog

## Unreleased — v0.4.0

- Add English and Vietnamese UI with a persistent System / English / Tiếng Việt menu in both the main menu and menu bar.
- Switch the complete native interface while idle without restarting the app or calling backend operations; preserve account choices, health, window size and scroll position.
- Translate forms, accessibility labels, confirmations, health/recovery messages, reports/activity and all stable backend error codes. Account names, conversation content and original diagnostics remain unchanged.
- Add isolated preference, backend catalog, live language-switch and native UI tests. Include Localization.swift in build and CI; remove hard-coded artifact version paths.

## v0.3.0 — 2026-10-15

- Audit UI-to-backend wiring with an actual AppKit checkbox click through an installed disposable runtime, including stale-profile rejection.
- Restore controls after dismissing operation details; tolerate malformed optional sync-report fields.
- Save private `last-verification.json` diagnostics for successful/failed verification and identify it in failure remediation.
- Complete backend processes through termination callbacks and make pipe draining interruptible on timeout, including inherited descendant pipes.

- Refresh native UI with a resizable Auto Layout window, semantic light/dark surfaces, readable account state badges, selection summary, empty-state guidance and recovery banner.
- Explain why sync is unavailable, retain scroll/focus on refresh, and add keyboard shortcuts and accessible per-account controls.
- Add a labelled account-creation sheet with inline validation, retry without losing input, and adaptive height for recovery instructions.

- Add desktop protocol v1 with capability negotiation, stable error codes and remediation; reject unsupported protocol requests before dispatch. Preserve ordinary CLI JSON results.
- Display clone health per profile and expose deliberate **Sửa** and **Kiểm tra → Phục hồi** actions.
- Share operation state between window and menu bar, serialize user actions while busy, and preserve errors across refreshes.
- Verify synchronized history before reopening apps, distinguishing verification and reopen failures from successful sync.
- Add macOS CI, installed-runtime Swift contract tests, and release checks for runtime source bytes, bundle metadata, signature and ZIP consistency.

- Add native history import with source/optional Desktop metadata selection and explicit target confirmation, independent verification, and a report/activity viewer with a bounded metadata-only activity log.
- Bump bundle version to 0.3.0 (build 3), include HistoryUI.swift in all build/test commands, and generate per-ZIP SHA256 sidecars.
- Support optional timestamped Developer ID Application signing with hardened runtime, and notarization through an existing notarytool Keychain profile; require Accepted status, staple validation and Gatekeeper assessment.
- Retain verified ad-hoc ZIP/checksum candidates as CI artifacts without publishing a release.
- Keep clones closed after post-sync verification fails and decode structured record-error diagnostics.
- Check external import sources for visible live sessions/open writers before writes and commit; refuse failed source inspection.
- Keep the real-bundle smoke test headless to avoid Keychain prompts from Electron under a synthetic HOME.

**Distribution status:** prepared source candidate; no tag/release published by this work. Default assets are ad-hoc signed, not notarized. No valid signing identity or matching notarytool profile metadata was found on the preparation host. Developer ID/notarization paths have synthetic command tests only; real Apple service and Intel runtime validation remain outstanding. See the [release guide](docs/release-0.3.0.md) for exact validation and manual gates.

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
