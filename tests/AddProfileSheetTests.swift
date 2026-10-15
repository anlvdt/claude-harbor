import AppKit

@main struct AddProfileSheetTests {
    @MainActor static func main() async {
        // Catch missing validation, incorrect trimming, and Unicode byte-count limits.
        for value in ["", "   ", "\t", "bad/name", "bad\\name", "bad:name", "bad\0name", "bad\rname", "bad\nname", "\nname", "name\r", String(repeating: "a", count: 61), String(repeating: "👩🏽‍💻", count: 20)] {
            precondition(ProfileNameValidation.message(for: value) != nil, "Accepted invalid name: \(value.debugDescription)")
        }
        for value in ["Work", "  Công việc  ", "个人", "👩🏽‍💻", String(repeating: "é", count: 60)] {
            precondition(ProfileNameValidation.message(for: value) == nil, "Rejected valid Unicode name")
        }

        _ = NSApplication.shared
        let sheet = AddProfileSheetController()
        var closes = 0
        sheet.onClose = { closes += 1 }
        var submissions = 0
        sheet.onSubmit = { _, _ in submissions += 1 }
        sheet.name.stringValue = "bad/name"
        await sheet.create()
        precondition(submissions == 0 && closes == 0)
        precondition(!sheet.errorLabel.stringValue.isEmpty)
        sheet.name.stringValue = "Work"
        sheet.validate(showError: false)
        precondition(sheet.submitButton.isEnabled)

        sheet.name.stringValue = "  Công việc  "
        sheet.kind.selectItem(at: 1)
        let originalName = sheet.name.stringValue
        var continuation: CheckedContinuation<Void, Never>?
        sheet.onSubmit = { name, kind in
            submissions += 1
            precondition(name == "Công việc" && kind == "magpie")
            await withCheckedContinuation { continuation = $0 }
            throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Gateway unavailable. Try again."])
        }
        let first = Task { await sheet.create() }
        while continuation == nil { await Task.yield() }
        precondition(!sheet.name.isEnabled && !sheet.kind.isEnabled && !sheet.submitButton.isEnabled)
        sheet.validate()
        precondition(!sheet.submitButton.isEnabled)
        let escapeHandled = sheet.control(sheet.name, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        precondition(escapeHandled && closes == 0, "Escape cancelled an active submission")
        await sheet.create()
        precondition(submissions == 1, "Reentrant creation reached the backend")
        continuation?.resume()
        await first.value
        precondition(closes == 0, "Failure closed the sheet")
        precondition(sheet.name.stringValue == originalName && sheet.kind.indexOfSelectedItem == 1)
        precondition(sheet.name.isEnabled && sheet.kind.isEnabled && sheet.submitButton.isEnabled)
        precondition(sheet.errorLabel.stringValue.contains("Gateway unavailable"))

        sheet.onSubmit = { name, kind in
            submissions += 1
            precondition(name == "Công việc" && kind == "magpie")
        }
        await sheet.create()
        precondition(submissions == 2 && closes == 1, "Retry must close exactly once on success")
        await sheet.create()
        precondition(submissions == 2 && closes == 1, "Closed sheet submitted again")

        let cancelled = AddProfileSheetController()
        var cancelCloses = 0
        cancelled.onClose = { cancelCloses += 1 }
        _ = cancelled.control(cancelled.name, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        _ = cancelled.control(cancelled.name, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        precondition(cancelCloses == 1, "Escape must close exactly once")

        let claude = AddProfileSheetController()
        claude.name.stringValue = " Personal "
        var claudeCreated = false
        claude.onSubmit = { name, kind in
            precondition(name == "Personal" && kind == "claude")
            claudeCreated = true
        }
        await claude.create()
        precondition(claudeCreated)
        let longError = AddProfileSheetController()
        longError.name.stringValue = "Fixture"
        let preview = longError.makeSheet()
        let oldHeight = preview.contentView!.bounds.height
        longError.onSubmit = { _, _ in
            throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: String(repeating: "Hướng dẫn phục hồi cần đọc đầy đủ. ", count: 15)])
        }
        await longError.create()
        precondition(preview.contentView!.bounds.height > oldHeight, "Long remediation must expand the sheet")
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--preview" {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for mode in [NSAppearance.Name.aqua, .darkAqua] {
                let previewController = AddProfileSheetController()
                previewController.name.stringValue = "Công việc"
                let window = previewController.makeSheet()
                window.appearance = NSAppearance(named: mode)
                previewController.validate()
                let view = window.contentView!
                view.wantsLayer = true; view.layoutSubtreeIfNeeded()
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let suffix = mode == .aqua ? "light" : "dark"
                    try! bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("add-account-\(suffix).png"))
                }
                window.close()
            }
        }
        preview.close()
        print("AddProfileSheetTests passed")
    }
}
