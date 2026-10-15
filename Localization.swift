import Foundation

enum AppLanguage: String {
    case english = "en"
    case vietnamese = "vi"
}

enum LanguagePreference: String {
    case system = "system"
    case english = "en"
    case vietnamese = "vi"
}

enum L10n {
    static var defaults: UserDefaults = .standard

    static var preference: LanguagePreference {
        LanguagePreference(rawValue: defaults.string(forKey: "HarborLanguage") ?? "system") ?? .system
    }

    static func setPreference(_ preference: LanguagePreference) {
        defaults.set(preference.rawValue, forKey: "HarborLanguage")
    }

    static func resolve(preference: LanguagePreference, preferredLanguages: [String]) -> AppLanguage {
        switch preference {
        case .english: return .english
        case .vietnamese: return .vietnamese
        case .system:
            for identifier in preferredLanguages {
                let base = identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
                if let supported = AppLanguage(rawValue: base) { return supported }
            }
            return .english
        }
    }

    #if BACKEND_TEST
    // Existing backend/UI fixtures use Vietnamese independently of the host locale.
    static var languageOverride: AppLanguage? = .vietnamese
    #endif

    static var language: AppLanguage {
        #if BACKEND_TEST
        if let languageOverride { return languageOverride }
        #endif
        return resolve(preference: preference, preferredLanguages: Locale.preferredLanguages)
    }

    static func backendError(code: String, message: String, remediation: String) -> String {
        guard language == .english else { return "\(message)\n\(remediation) [\(code)]" }
        let translated = englishBackendErrors[code] ?? (
            "The operation could not be completed.",
            "Run Check to review profile and recovery status; keep your backups."
        )
        return "\(translated.0)\n\(translated.1) [\(code)]"
    }

    // Stable codes from backend_protocol.py; never display raw backend text in English.
    private static let englishBackendErrors: [String: (String, String)] = [
        "protocol_incompatible": (
            "The interface and runtime are incompatible.",
            "Reopen Harbor from the same installation to update the runtime."
        ),
        "invalid_request": (
            "The command or parameters are invalid.",
            "Refresh Harbor and try again."
        ),
        "invalid_profile_name": (
            "The profile name is invalid.",
            "Use 1 to 60 characters without /, \\, :, NUL characters, or line breaks."
        ),
        "duplicate_profile": (
            "This profile or app name is already in use.",
            "Choose a different name for the new Claude copy."
        ),
        "source_unavailable": (
            "The original Claude Desktop app could not be found.",
            "Install Claude Desktop at /Applications/Claude.app and try again."
        ),
        "store_busy": (
            "The data is in use by an app or another operation.",
            "Wait for the current operation to finish; close profiles before repairing or recovering."
        ),
        "profiles_running": (
            "One or more profiles are still running.",
            "Close the profiles and try again."
        ),
        "import_source_busy": (
            "The import source is in use.",
            "Close Claude and any tools writing to the source, or use a backup that is no longer being written to, then try again."
        ),
        "import_source_unchecked": (
            "The import source could not be checked for active writes.",
            "Check source read permissions and the lsof tool; use a backup that is no longer being written to and try again."
        ),
        "profile_missing": (
            "The selected profile could not be found.",
            "Refresh the list and select the profile again."
        ),
        "profiles_not_ready": (
            "There are not enough ready profiles for this operation.",
            "Sign in, open the Code tab, create a local session, and select at least two profiles to sync."
        ),
        "clone_stale": (
            "The Claude copy needs repair before syncing.",
            "Close the profiles, select Check, and repair the affected Claude copy."
        ),
        "recovery_required": (
            "There is an unfinished transaction or an unreadable journal.",
            "Close the profiles and use Recover in Check. Keep your backups if recovery is blocked."
        ),
        "verification_failed": (
            "Verification found inconsistent history.",
            "Open Reports & Backups and review last-verification.json before syncing again."
        ),
        "permission_denied": (
            "Access to the required data was denied.",
            "Check access permissions for the data folder and Claude copies."
        ),
        "operation_failed": (
            "The operation could not be completed.",
            "Run Check to review profile and recovery status; keep your backups."
        ),
    ]
}

func L(_ vietnamese: String, _ english: String) -> String {
    L10n.language == .vietnamese ? vietnamese : english
}
