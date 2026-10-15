# Harbor language support — 0.4.0

Harbor supports English and Vietnamese through a saved `HarborLanguage` preference in its application UserDefaults domain. The main menu and menu-bar icon expose **Language / Ngôn ngữ → System, English, Tiếng Việt**. System selects the first supported macOS preferred language and falls back to English. Native macOS-owned dialogs/errors follow macOS settings.

`Localization.swift` provides `L(vi, en)` for application-owned text and a code-based English catalog for backend failures. Unknown failure codes use a safe generic English message. Protocol v1 and existing CLI JSON remain compatible; `busyDetails` adds structured reasons for waiting while preserving legacy `busy` text.

Switching language is allowed only while idle with no attached dialog. It rebuilds the native controls, menus, accessibility labels and hints from the current summary without making backend calls. Profile choices, health, window frame and scroll position are retained. The latest notice remains visible in its original language, so verification/recovery warnings survive repeated language switches. New notices use the selected language. Account names, session titles, history, original diagnostics and private report files are never translated or rewritten.

## Validation on 15 October 2026

- 147 Python tests passed, including structured busy reasons, source-title preservation and localization source inclusion in release builds.
- Native backend/UI tests passed, including English controls/form labels, persistence through isolated preferences, two language switches after a verification failure, busy/sheet guards, preserved names/selections/frame, and zero backend calls during switching.
- Localization tests passed for language resolution, persisted preference, original user text and all 16 backend error codes. Add-account sheet tests passed.
- Arm64 0.4.0/build 4 app, ZIP and SHA256 verification passed. This is an ad-hoc local build, not a published release.
- Installed Harbor at `~/Applications/Claude Harbor.app`, retaining the previous app under `~/Library/Application Support/ClaudeHarborAppBackups/20261015-155158/`.
- Verified real UI switching English → Vietnamese → English, opened/cancelled the English add-account form, and opened/closed the English report viewer. The saved preference is English. Installed app/runtime match source; registry bytes and sync selections are unchanged.

No real-profile sync, repair, login, history import or credential changes were performed. The v0.4.0 release notes record the successful GitHub CI run and artifact checksum used for distribution.
