// Render the actual AppKit views with public demo data; never launch Claude.
// Compile with -D BACKEND_TEST and the app's Swift source files.
import AppKit
import Foundation

@main struct ScreenshotCapture {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "Screenshots", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pass an output directory."])
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("HarborScreenshots-" + UUID().uuidString)
        let suite = "Harbor.Screenshots." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let oldDefaults = L10n.defaults
        let oldLanguage = L10n.languageOverride
        L10n.defaults = defaults; L10n.languageOverride = .english
        L10n.setPreference(.english)
        defer {
            defaults.removePersistentDomain(forName: suite)
            L10n.defaults = oldDefaults; L10n.languageOverride = oldLanguage
            try? FileManager.default.removeItem(at: temporary)
        }
        let manager = Manager()
        manager.request = { _ in fatalError("Screenshots must never invoke the backend") }
        manager.openRequest = { _ in fatalError("Screenshots must never launch profiles") }
        manager.prepareWindow(); manager.runtimeReady = true
        defer { manager.window.close(); NSStatusBar.system.removeStatusItem(manager.item) }
        let names = ["Claude Work", "Claude Personal", "Claude Research", "Magpie Local"]
        let profiles = names.enumerated().map { index, name in
            Profile(id: "demo\(index)", name: name, kind: index == 3 ? "magpie" : "claude", bundle: "/tmp/harbor-demo-\(index).app", bundleID: "example.harbor.demo\(index)", ready: index < 2, running: false, syncEnabled: index < 2, sessions: [125, 84, 0, 0][index], archived: 0, health: [])
        }
        let report = Report(profiles: 2, sessions: 209, newBranches: 2, filesChanged: 18, backup: "demo-backup", warnings: 0, pending: [])
        manager.render(Summary(profiles: profiles, pending: ["demo2", "demo3"], lastSync: report, issues: []))
        manager.setPhase(.idle)
        manager.activityStore = OperationActivityStore(directory: temporary)
        let timestamp = ISO8601DateFormatter().date(from: "2026-10-15T08:00:00Z")!
        try manager.activityStore!.append(OperationSummary(kind: .sync, outcome: .succeeded, report: report, date: timestamp))
        try manager.activityStore!.append(OperationSummary(kind: .verify, outcome: .succeeded, date: timestamp.addingTimeInterval(3)))
        let verification: [String: Any] = ["profiles": 2, "sessionGroups": 209, "incompleteGroups": 0, "missingTranscripts": [String](), "conversationMismatches": [String](), "auxiliaryMismatches": [String](), "duplicateMembers": [String](), "recordErrors": [[String: String]]()]
        try JSONSerialization.data(withJSONObject: verification).write(to: temporary.appendingPathComponent("last-verification.json"))
        precondition(manager.add.title == "Add account" && manager.sync.title == "Sync 2 accounts")
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            manager.window.appearance = NSAppearance(named: appearance)
            manager.window.setContentSize(NSSize(width: 960, height: 820))
            try capture(manager.window, to: output.appendingPathComponent("claude-harbor-0.4.0-en-\(suffix).png"))
        }
        manager.window.appearance = NSAppearance(named: .aqua)
        let form = AddProfileSheetController()
        form.name.stringValue = "Work"
        let sheet = form.makeSheet(); sheet.appearance = NSAppearance(named: .aqua)
        form.validate()
        precondition(form.submitButton.title == "Create and open")
        try capture(sheet, to: output.appendingPathComponent("claude-harbor-0.4.0-en-add-account.png"))
        sheet.close()
        manager.showReport()
        guard let reportSheet = manager.window.attachedSheet else {
            throw NSError(domain: "Screenshots", code: 2, userInfo: [NSLocalizedDescriptionKey: "Report sheet did not open."])
        }
        reportSheet.appearance = NSAppearance(named: .aqua)
        try capture(reportSheet, to: output.appendingPathComponent("claude-harbor-0.4.0-en-reports.png"))
        manager.window.endSheet(reportSheet)
        print("Captured four English v0.4.0 views using isolated demonstration data.")
    }

    @MainActor static func capture(_ window: NSWindow, to url: URL) throws {
        let view = window.contentView!
        view.wantsLayer = true; view.layoutSubtreeIfNeeded()
        var data: Data?
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            data = bitmap.representation(using: .png, properties: [:])
        }
        try data!.write(to: url)
    }
}
