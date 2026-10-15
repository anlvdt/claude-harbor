import Foundation

@main struct LocalizationTests {
    static func main() throws {
        let suiteName = "Harbor.LocalizationTests.\(UUID().uuidString)"
        let isolated = UserDefaults(suiteName: suiteName)!
        let previousDefaults = L10n.defaults
        L10n.defaults = isolated
        defer {
            isolated.removePersistentDomain(forName: suiteName)
            L10n.defaults = previousDefaults
        }
        #if BACKEND_TEST
        precondition(L10n.languageOverride == .vietnamese)
        let previousOverride = L10n.languageOverride
        L10n.languageOverride = nil
        defer { L10n.languageOverride = previousOverride }
        #endif

        precondition(L10n.resolve(preference: .system, preferredLanguages: []) == .english)
        for tag in ["en", "en-US", "en-GB", "EN-us"] {
            precondition(L10n.resolve(preference: .system, preferredLanguages: [tag]) == .english)
        }
        for tag in ["vi", "vi-VN", "VI-vn"] {
            precondition(L10n.resolve(preference: .system, preferredLanguages: [tag]) == .vietnamese)
        }
        precondition(L10n.resolve(preference: .system, preferredLanguages: ["fr", "vi-VN", "en-US"]) == .vietnamese)
        precondition(L10n.resolve(preference: .system, preferredLanguages: ["ja", "en-US", "vi"]) == .english)
        precondition(L10n.resolve(preference: .system, preferredLanguages: ["fr", "ja", "vietnamese", "english"]) == .english)
        precondition(L10n.resolve(preference: .english, preferredLanguages: ["vi"]) == .english)
        precondition(L10n.resolve(preference: .vietnamese, preferredLanguages: ["en"]) == .vietnamese)

        precondition(L10n.preference == .system)
        isolated.set("invalid", forKey: "HarborLanguage")
        precondition(L10n.preference == .system)
        for preference in [LanguagePreference.english, .vietnamese, .system] {
            L10n.setPreference(preference)
            precondition(isolated.string(forKey: "HarborLanguage") == preference.rawValue)
            precondition(L10n.preference == preference)
            let reopened = UserDefaults(suiteName: suiteName)!
            precondition(reopened.string(forKey: "HarborLanguage") == preference.rawValue)
        }
        L10n.setPreference(.system)
        precondition(L10n.language == L10n.resolve(preference: .system, preferredLanguages: Locale.preferredLanguages))

        // Read the source catalog so newly added stable codes must be translated too.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", "import json, backend_protocol; print(json.dumps(backend_protocol.MESSAGES))"]
        process.currentDirectoryURL = root
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        let catalog = try JSONDecoder().decode([String: [String]].self, from: data)
        precondition(!catalog.isEmpty)
        let generic = "The operation could not be completed.\nRun Check to review profile and recovery status; keep your backups."
        for (code, original) in catalog {
            L10n.setPreference(.english)
            let translated = L10n.backendError(code: code, message: original[0], remediation: original[1])
            precondition(translated.hasSuffix(" [\(code)]"))
            if code != "operation_failed" {
                precondition(translated != "\(generic) [\(code)]", "Missing English catalog entry: \(code)")
            }
            precondition(translated.allSatisfy(\.isASCII), "Non-English catalog entry: \(code)")
            precondition(!translated.contains(original[0]) && !translated.contains(original[1]))
            precondition(translated == L10n.backendError(code: code, message: "PRIVATE MESSAGE", remediation: "PRIVATE REMEDIATION"))
            L10n.setPreference(.vietnamese)
            precondition(L10n.backendError(code: code, message: original[0], remediation: original[1]) == "\(original[0])\n\(original[1]) [\(code)]")
        }
        L10n.setPreference(.english)
        precondition(L10n.backendError(code: "future_code", message: "Bí mật", remediation: "Riêng tư") == "\(generic) [future_code]")
        let userContent = "Công việc / Đặng 🛟"
        precondition(L("Mở \(userContent)", "Open \(userContent)") == "Open \(userContent)")
        L10n.setPreference(.vietnamese)
        precondition(L("Mở \(userContent)", "Open \(userContent)") == "Mở \(userContent)")
        precondition(L10n.backendError(code: "future_code", message: "Lỗi", remediation: "Thử lại") == "Lỗi\nThử lại [future_code]")
        #if BACKEND_TEST
        L10n.setPreference(.english)
        L10n.languageOverride = .vietnamese
        precondition(L10n.language == .vietnamese)
        L10n.setPreference(.vietnamese)
        L10n.languageOverride = .english
        precondition(L10n.language == .english)
        #endif
        print("Localization tests passed (\(catalog.count) backend codes).")
    }
}
