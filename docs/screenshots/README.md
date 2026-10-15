# README screenshots

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
