# README screenshots

## English — v0.4.0

The four `claude-harbor-0.4.0-en-*.png` images were captured on 15 October 2026 from the actual native AppKit views of the published v0.4.0 source (release commit `8eff4c3`, merged into main as `c6d4564`). They use English demonstration account names and synthetic history/report totals. No real account data or authenticated Claude behavior is shown. The PNGs are unedited view captures without window chrome.

- `claude-harbor-0.4.0-en-light.png`: account manager, light appearance.
- `claude-harbor-0.4.0-en-dark.png`: the same accounts, dark appearance.
- `claude-harbor-0.4.0-en-add-account.png`: add-account form.
- `claude-harbor-0.4.0-en-reports.png`: reports and recent activity.

To reproduce on macOS from the repository root:

```sh
swiftc -D BACKEND_TEST -parse-as-library Localization.swift AccountManager.swift HarborUI.swift AddProfileSheet.swift HistoryUI.swift scripts/capture_screenshots.swift -o /tmp/Harbor040Screenshots
/tmp/Harbor040Screenshots /tmp/harbor-040-en-screenshots
```

The renderer forces English only in its own process, uses a temporary UserDefaults suite and a temporary report/activity folder, and removes both afterward. Backend and app-launch callbacks deliberately fail if invoked. It does not launch Claude, access real profile history or change the installed app's language preference. Copy the generated PNG files into this directory after visual inspection.

## Earlier Vietnamese captures

The `claude-harbor-0.3.0-*.png` images were captured on 15 October 2026 from the native AppKit views at release commit `ededb79`. They use demonstration profiles and fixture history; they do not show real account information or verify authenticated Claude behavior. Images are unedited PNG captures of the views, without window chrome.

- `claude-harbor-0.3.0-light.png`: account manager, light appearance.
- `claude-harbor-0.3.0-dark.png`: the same fixture, dark appearance.
- `claude-harbor-0.3.0-add-account.png`: add-account form, light appearance.

To capture the current UI on macOS, from the repository root (the test build forces Vietnamese independently of the host language):

```sh
swiftc -D BACKEND_TEST -parse-as-library Localization.swift AccountManager.swift HarborUI.swift AddProfileSheet.swift HistoryUI.swift tests/BackendProcessTests.swift -o /tmp/HarborScreenshotTests
/tmp/HarborScreenshotTests --preview-suite /tmp/harbor-screenshots
swiftc -D BACKEND_TEST -parse-as-library Localization.swift AccountManager.swift HarborUI.swift AddProfileSheet.swift HistoryUI.swift tests/AddProfileSheetTests.swift -o /tmp/HarborSheetScreenshotTests
/tmp/HarborSheetScreenshotTests --preview /tmp/harbor-screenshots
```

Copy `accounts-light.png`, `accounts-dark.png` and `add-account-light.png` to the versioned names above. Both test programs also run their normal checks. They do not launch Claude or use real profile history. Older unversioned images remain for historical references.
