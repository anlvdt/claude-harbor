import Foundation
import AppKit
@main struct BackendTests {
    static func main() async throws {
        let data = try await executePython(["-c", "import sys; sys.stdout.write('x'*1000000); sys.stderr.write('e'*200000)"])
        precondition(data.count == 1000000)
        for _ in 0..<24 {
            let short = try await executePython(["-c", "print('short-lived')"], timeout: 2)
            precondition(String(decoding: short, as: UTF8.self) == "short-lived\n")
        }
        do {
            _ = try await executePython(["-c", "import time; time.sleep(20)"], timeout: 0.2)
            fatalError("timeout was not enforced")
        } catch { precondition(error.localizedDescription.contains("timed out")) }
        let inheritedPipeStart = Date()
        do {
            _ = try await executePython(["-c", "import subprocess; subprocess.Popen(['/bin/sleep', '3'])"], timeout: 0.1)
            fatalError("inherited pipe timeout was not enforced")
        } catch { precondition(error.localizedDescription.contains("timed out")) }
        precondition(Date().timeIntervalSince(inheritedPipeStart) < 1.5, "A descendant holding stdout delayed timeout")
        do {
            _ = try await executePython(["-c", "import sys; sys.stdout.write('x'*10000000)"])
            fatalError("output bound was not enforced")
        } catch { precondition(error.localizedDescription.contains("limit")) }
        let response = Data(#"{"protocolVersion":1,"ok":true,"result":{"profiles":[]}}"#.utf8)
        let decoded = try decodeDesktopResponse(response, status: 0)
        precondition(String(decoding: decoded, as: UTF8.self).contains("profiles"))
        for invalid in [
            #"{"protocolVersion":99,"ok":true,"result":{}}"#,
            #"{"protocolVersion":1,"ok":true}"#,
            #"{"profiles":[]}"#,
            #"{"protocolVersion":true,"ok":true,"result":{}}"#,
            #"{"protocolVersion":1,"ok":false,"error":{"code":"oops"}}"#,
            "private raw backend output",
        ] {
            do {
                _ = try decodeDesktopResponse(Data(invalid.utf8), status: 0)
                fatalError("invalid response accepted")
            } catch let error as BackendFailure {
                precondition(error.code == "protocol_incompatible")
                precondition(!error.localizedDescription.contains("private raw"))
            }
        }
        do {
            _ = try decodeDesktopResponse(response, status: 1)
            fatalError("exit status mismatch accepted")
        } catch let error as BackendFailure { precondition(error.code == "protocol_incompatible") }
        let failure = Data(#"{"protocolVersion":1,"ok":false,"error":{"code":"store_busy","message":"Busy","remediation":"Wait"}}"#.utf8)
        do {
            _ = try decodeDesktopResponse(failure, status: 1)
            fatalError("machine error accepted as success")
        } catch let error as BackendFailure {
            precondition(error.code == "store_busy")
            precondition(error.localizedDescription.contains("Wait"))
        }
        let incompatible = RuntimeCapabilities(protocolVersion: 1, features: ["structured_errors"])
        precondition(!incompatible.isCompatible)
        precondition(OperationPhase.waiting.canCancel)
        precondition(!OperationPhase.syncing.canCancel)
        precondition(OperationPhase.syncing.isBusy)
        precondition(!OperationPhase.idle.isBusy)
        let emptyAvailability = SyncAvailability(profiles: [], runtimeReady: true, recoveryNeeded: false, phase: .idle)
        precondition(!emptyAvailability.isEnabled && emptyAvailability.explanation.contains("Thêm"))
        precondition(ProfileNameValidation.message(for: "bad/name") != nil)
        precondition(ProfileNameValidation.message(for: "   ") != nil)
        precondition(ProfileNameValidation.message(for: "Công việc") == nil)
        try await MainActor.run {
            _ = NSApplication.shared
            let manager = Manager()
            manager.prepareWindow()
            manager.runtimeReady = true
            manager.setPhase(.syncing)
            precondition(!manager.add.isEnabled && !manager.health.isEnabled && !manager.refresh.isEnabled)
            precondition(manager.menuStatus.title == OperationPhase.syncing.title)
            manager.setPhase(.waiting)
            precondition(manager.sync.isEnabled && manager.sync.title == "Dừng chờ")
            manager.status.stringValue = "Đồng bộ thất bại\nCách xử lý"
            manager.setPhase(.idle)
            precondition(manager.menuStatus.title == "Đồng bộ thất bại")
            precondition(!manager.sync.isEnabled) // no eligible profiles
            manager.runtimeReady = false
            manager.setPhase(.idle)
            precondition(!manager.add.isEnabled && manager.refresh.isEnabled)
            let fixture = Data(#"{"profiles":[{"id":"work","name":"Claude Công việc","kind":"claude","bundle":"/tmp/fixture.app","bundleID":"test.work","ready":true,"running":true,"syncEnabled":true,"sessions":125,"archived":0,"health":[]},{"id":"personal","name":"Claude Cá nhân","kind":"claude","bundle":"/tmp/fixture2.app","bundleID":"test.personal","ready":true,"running":false,"syncEnabled":true,"sessions":84,"archived":0,"health":[{"profile":"personal","code":"clone_version_changed","detail":"Fixture only","blocking":true}]}],"pending":[],"lastSync":null,"issues":[]}"#.utf8)
            manager.runtimeReady = true
            manager.render(try JSONDecoder().decode(Summary.self, from: fixture))
            manager.setPhase(.idle)
            precondition(manager.window.styleMask.contains(.resizable))
            precondition(manager.emptyState.isHidden)
            precondition(manager.footer.stringValue.contains("Sửa"))
            precondition(manager.selectionLabel.stringValue.contains("2"))
            precondition(manager.rows.arrangedSubviews.count == 2)
            let staleRow = manager.rows.arrangedSubviews[1] as! NSStackView
            precondition(staleRow.arrangedSubviews.contains { ($0 as? NSButton)?.title == "Sửa" })
            precondition(!manager.sync.isEnabled)
            let syncMenu = manager.item.menu?.items.first { $0.action == #selector(Manager.synchronize) }
            precondition(syncMenu?.isEnabled == false)
            let signatureFault = HealthIssue(profile: "work", code: "invalid_signature", detail: "Synthetic", blocking: true)
            manager.applyHealthReport(HealthReport(issues: [signatureFault], ok: false))
            let workRow = manager.rows.arrangedSubviews[0] as! NSStackView
            precondition(workRow.arrangedSubviews.contains { ($0 as? NSButton)?.title == "Sửa" })
            manager.render(try JSONDecoder().decode(Summary.self, from: fixture))
            precondition(manager.profiles[0].health.contains { $0.code == "invalid_signature" })
            manager.applyHealthReport(HealthReport(issues: [], ok: true))
            precondition(!manager.profiles[0].health.contains { $0.code == "invalid_signature" })
            let newFault = HealthIssue(profile: "personal", code: "missing_binary", detail: "Synthetic", blocking: true)
            manager.applyHealthReport(HealthReport(issues: [newFault], ok: false))
            precondition(manager.profiles[1].health.contains { $0.code == "missing_binary" })
            precondition(!manager.sync.isEnabled)
            manager.applyHealthReport(HealthReport(issues: [], ok: true))
            precondition(manager.profiles.allSatisfy { $0.health.isEmpty })
            manager.render(try JSONDecoder().decode(Summary.self, from: fixture))
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--preview" {
                let view = manager.window.contentView!
                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                view.layoutSubtreeIfNeeded()
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            }
            var healthyProfiles = manager.profiles
            healthyProfiles[1].health = []
            healthyProfiles.append(Profile(id: "third", name: "Third", kind: "claude", bundle: "/tmp/fixture3.app", bundleID: "test.third", ready: true, running: false, syncEnabled: true, sessions: 1, archived: 0, health: []))
            manager.render(Summary(profiles: healthyProfiles, pending: [], lastSync: nil, issues: []))
            precondition(manager.sync.isEnabled)
            manager.applyHealthReport(HealthReport(issues: [signatureFault], ok: false))
            precondition(!manager.sync.isEnabled && syncMenu?.isEnabled == false)
            manager.render(Summary(profiles: [], pending: [], lastSync: nil, issues: []))
            precondition(!manager.emptyState.isHidden)
            precondition(!manager.openAll.isEnabled)
            precondition(manager.footer.stringValue.contains("Thêm"))
            let pending = Profile(id: "pending", name: "Pending", kind: "claude", bundle: "/tmp/pending.app", bundleID: "test.pending", ready: false, running: false, syncEnabled: false, sessions: 0, archived: 0, health: [])
            let pendingAvailability = SyncAvailability(profiles: [pending], runtimeReady: true, recoveryNeeded: false, phase: .idle)
            precondition(!pendingAvailability.isEnabled)
            let recoveryAvailability = SyncAvailability(profiles: healthyProfiles, runtimeReady: true, recoveryNeeded: true, phase: .idle)
            precondition(!recoveryAvailability.isEnabled && recoveryAvailability.explanation.contains("phục hồi"))
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--preview-suite" {
                try renderPreviews(manager, directory: URL(fileURLWithPath: CommandLine.arguments[2]))
            }
            NSStatusBar.system.removeStatusItem(manager.item)
            manager.window.close()
        }
        try await testFailedSyncRefresh()
        try await testSyncVerification()
        try await testDetailsDismissal()
        try testActivityStore()
        try await testHistoryActions()

        // Stage the real dispatcher + runtime in a throwaway root. No real profiles.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let staging = """
        import sys
        from pathlib import Path
        sys.path.insert(0, sys.argv[1])
        import bootstrap, profile_store as store
        store.ROOT=Path(sys.argv[2]); store.REGISTRY=store.ROOT/'profiles.json'
        bootstrap.install_runtime(Path(sys.argv[1]))
        """
        // profile_store uses Path.home(): give only the child an isolated HOME.
        let home = temporary.appendingPathComponent("home")
        let installed = home.appendingPathComponent("Library/Application Support/ClaudeHarbor")
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Stage directly at the isolated home path for the end-to-end CLI test.
        _ = try await executePython(["-c", staging, source.path, installed.path])
        let capabilities = try await backend(["capabilities"], directory: installed, environment: ["HOME": home.path])
        let runtime = try JSONDecoder().decode(RuntimeCapabilities.self, from: capabilities)
        precondition(runtime.isCompatible)
        let summary = try JSONDecoder().decode(Summary.self, from: try await backend(["status"], directory: installed, environment: ["HOME": home.path]))
        precondition(summary.profiles.isEmpty)
        let health = try JSONDecoder().decode(HealthReport.self, from: try await backend(["doctor"], directory: installed, environment: ["HOME": home.path]))
        precondition(health.ok && health.issues.isEmpty)
        _ = try await backend(["recover"], directory: installed, environment: ["HOME": home.path])
        for (arguments, expectedCode) in [
            (["repair", "missing"], "profile_missing"),
            (["verify"], "profiles_not_ready"),
            (["check"], "profiles_not_ready"),
            (["sync"], "profiles_not_ready"),
            (["create", "bad/name", "claude"], "invalid_profile_name"),
            (["import"], "invalid_request"),
        ] {
            do {
                _ = try await backend(arguments, directory: installed, environment: ["HOME": home.path])
                fatalError("invalid installed-runtime request succeeded: \(arguments[0])")
            } catch let error as BackendFailure { precondition(error.code == expectedCode) }
        }
        do {
            _ = try await backend(["select", "missing", "true"], directory: installed, environment: ["HOME": home.path])
            fatalError("missing profile accepted")
        } catch let error as BackendFailure { precondition(error.code == "profile_missing") }
        try await testInstalledSelection(directory: installed, home: home)
        print("PASS: process bounds, desktop protocol, capability, operation state, installed runtime contract, native history import/verify/report, bounded private activity")
    }

    @MainActor static func testInstalledSelection(directory: URL, home: URL) async throws {
        let setup = """
        import sys, json
        from pathlib import Path
        root=Path(sys.argv[1])
        generation=json.loads((root/'current-runtime.json').read_text())['generation']
        sys.path.insert(0, str(root/'runtimes'/generation))
        import profile_store as store
        profiles=[] if sys.argv[2]=='empty' else [dict(id='fixture', name='Disposable account', kind='claude', bundle=str(Path.home()/'Applications/Fixture.app'), bundleID='test.disposable', model='sonnet', syncEnabled=False)]
        store.save(profiles)
        """
        _ = try await executePython(["-c", setup, directory.path, "profile"], environment: ["HOME": home.path])
        let manager = Manager(); manager.prepareWindow(); manager.runtimeReady = true
        defer { NSStatusBar.system.removeStatusItem(manager.item); manager.window.close() }
        manager.request = { try await backend($0, directory: directory, environment: ["HOME": home.path]) }
        let loaded = await manager.load()
        precondition(loaded && manager.profiles.count == 1)
        manager.setPhase(.idle)
        func checkbox() -> NSButton {
            let row = manager.rows.arrangedSubviews[0] as! NSStackView
            return row.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "sync.fixture" }!
        }
        precondition(checkbox().target === manager && checkbox().action == #selector(Manager.selectForSync(_:)))
        checkbox().performClick(nil)
        for _ in 0..<250 {
            if !manager.working { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(!manager.working && manager.profiles[0].syncEnabled)
        let persisted = try JSONDecoder().decode(Summary.self, from: try await backend(["status"], directory: directory, environment: ["HOME": home.path]))
        precondition(persisted.profiles[0].syncEnabled, "Checkbox did not persist through the installed runtime")
        // Simulate removal between render and click. The real runtime must reject
        // the stale identity, and refreshing the rows must preserve that error.
        _ = try await executePython(["-c", setup, directory.path, "empty"], environment: ["HOME": home.path])
        checkbox().performClick(nil)
        for _ in 0..<250 {
            if !manager.working { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(!manager.working && manager.profiles.isEmpty)
        precondition(manager.status.stringValue.contains("profile_missing"))
        precondition(!manager.sync.isEnabled)
    }

    static func testActivityStore() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = OperationActivityStore(directory: temporary)
        let report = Report(profiles: 2, sessions: 3, newBranches: 1, filesChanged: 4, backup: "/private/SECRET-backup", warnings: 0, pending: ["SECRET-account"])
        for index in 0..<105 {
            try store.append(OperationSummary(kind: .historyImport, outcome: .succeeded, report: report, date: Date(timeIntervalSince1970: Double(index))))
        }
        let entries = try store.load()
        precondition(entries.count == 100 && entries.first?.date == Date(timeIntervalSince1970: 5))
        precondition(entries.last?.sessions == 3 && entries.last?.filesChanged == 4)
        let persisted = try String(contentsOf: store.file, encoding: .utf8)
        precondition(!persisted.contains("SECRET") && !persisted.contains("backup") && !persisted.contains("pending"))
        let permissions = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        // Corrupt and oversized activity logs stay intact; failures never erase them.
        try Data("broken".utf8).write(to: store.file)
        do { try store.append(OperationSummary(kind: .verify, outcome: .failed)); fatalError("corrupt log accepted") } catch {}
        let corrupt = try String(contentsOf: store.file, encoding: .utf8)
        precondition(corrupt == "broken")
        try Data(repeating: 0x20, count: OperationActivityStore.byteLimit + 1).write(to: store.file)
        do { _ = try store.load(); fatalError("oversized log accepted") } catch {}
        try FileManager.default.removeItem(at: store.file)
        let outside = temporary.appendingPathComponent("outside.json")
        try Data("[]".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: store.file, withDestinationURL: outside)
        do { _ = try store.load(); fatalError("symlinked log accepted") } catch {}
        do { try store.append(OperationSummary(kind: .verify, outcome: .failed)); fatalError("symlinked log overwritten") } catch {}
        let unchanged = try String(contentsOf: outside, encoding: .utf8)
        precondition(unchanged == "[]")
    }

    @MainActor static func testHistoryActions() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = temporary.appendingPathComponent("SECRET-source with spaces")
        let desktop = temporary.appendingPathComponent("SECRET-desktop")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let validatedSource = try HistoryImportSource.validate(source)
        do { _ = try HistoryImportSource.validate(temporary); fatalError("source without projects accepted") } catch {}
        let profile = Profile(id: "fixture", name: "SECRET-account", kind: "claude", bundle: "/tmp/fixture.app", bundleID: "test.fixture", ready: true, running: false, syncEnabled: true, sessions: 2, archived: 0, health: [])
        let manager = Manager(); manager.prepareWindow(); manager.runtimeReady = true
        // BACKEND_TEST defaults to no activity storage: earlier suites cannot touch real root.
        precondition(manager.activityStore == nil)
        let store = OperationActivityStore(directory: temporary.appendingPathComponent("activity"))
        manager.activityStore = store
        defer { NSStatusBar.system.removeStatusItem(manager.item); manager.window.close() }
        manager.render(Summary(profiles: [profile], pending: [], lastSync: nil, issues: []))
        manager.setPhase(.idle)
        precondition(manager.importButton.isEnabled && manager.verifyButton.isEnabled)
        let panel = manager.historyFolderPanel()
        precondition(panel.canChooseDirectories && !panel.canChooseFiles && !panel.allowsMultipleSelection && panel.showsHiddenFiles && !panel.canCreateDirectories)
        let confirmation = HistoryImportSource.confirmation(source: source, targets: [profile], desktopRoot: desktop)
        precondition(confirmation.contains(source.path) && confirmation.contains(profile.name) && confirmation.contains(desktop.path))
        precondition(HistoryImportSource.confirmation(source: source, targets: [profile]).contains("Không dùng (mặc định)"))
        let verification = Data(#"{"profiles":1,"sessionGroups":2,"incompleteGroups":0,"missingTranscripts":[],"conversationMismatches":[],"auxiliaryMismatches":[],"duplicateMembers":[],"recordErrors":[]}"#.utf8)
        let status = Data(#"{"profiles":[{"id":"fixture","name":"SECRET-account","kind":"claude","bundle":"/tmp/fixture.app","bundleID":"test.fixture","ready":true,"running":false,"syncEnabled":true,"sessions":2,"archived":0,"health":[]}],"pending":[],"lastSync":{"profiles":1,"sessions":2,"newBranches":0,"filesChanged":3,"backup":"SECRET-backup"},"issues":[]}"#.utf8)
        var calls: [[String]] = []
        var failVerify = false
        manager.request = { args in
            calls.append(args)
            switch args[0] {
            case "import":
                precondition(manager.phase == .importing && !manager.importButton.isEnabled && !manager.verifyButton.isEnabled)
                return Data(#"{"profiles":1,"sessions":2,"newBranches":0,"filesChanged":3,"backup":"SECRET-backup","warnings":0}"#.utf8)
            case "verify":
                precondition(manager.phase == .verifying)
                if failVerify { throw BackendFailure(code: "verification_failed", message: "SECRET-diagnostic", remediation: "Inspect report") }
                return verification
            case "status": return status
            default: fatalError("unexpected history command")
            }
        }
        // Guards stop concurrent work, recovery, empty selection, and running apps.
        manager.setPhase(.syncing)
        await manager.performHistoryImport(source: source, targetIDs: [profile.id])
        await manager.performHistoryVerification()
        precondition(calls.isEmpty)
        manager.setPhase(.idle); manager.recoveryNeeded = true; manager.updateControls()
        precondition(!manager.importButton.isEnabled && !manager.verifyButton.isEnabled)
        await manager.performHistoryVerification(); precondition(calls.isEmpty)
        manager.recoveryNeeded = false
        await manager.performHistoryImport(source: source, targetIDs: ["unselected"])
        precondition(calls.isEmpty)
        manager.profiles = []; manager.updateControls()
        precondition(!manager.importButton.isEnabled && !manager.verifyButton.isEnabled)
        manager.profiles = [Profile(id: profile.id, name: profile.name, kind: profile.kind, bundle: profile.bundle, bundleID: profile.bundleID, ready: true, running: true, syncEnabled: true, sessions: 2, archived: 0, health: [])]
        precondition(!manager.historyActionAvailable)
        manager.profiles = [profile]; manager.updateControls()
        await manager.performHistoryImport(source: source, targetIDs: [profile.id], desktopRoot: desktop)
        precondition(calls.map { $0[0] } == ["import", "verify", "status"])
        precondition(calls[0] == ["import", "--source", validatedSource.path, "--to", "fixture", "--desktop-root", desktop.path])
        precondition(manager.phase == .idle && manager.status.stringValue.contains("Đã nhập 2 phiên"))
        calls.removeAll(); failVerify = true
        await manager.performHistoryImport(source: source, targetIDs: [profile.id])
        precondition(calls[0] == ["import", "--source", validatedSource.path, "--to", "fixture"])
        precondition(calls.map { $0[0] } == ["import", "verify", "status"])
        precondition(manager.status.stringValue.contains("Đã ghi nhập nhưng chưa xác minh thành công"))
        let importOutcome = try store.load().last?.outcome
        precondition(importOutcome == .needsAttention)
        calls.removeAll(); failVerify = false
        await manager.performHistoryVerification()
        precondition(calls.map { $0[0] } == ["verify", "status"] && manager.status.stringValue.contains("Đã xác minh"))
        calls.removeAll(); failVerify = true
        await manager.performHistoryVerification()
        precondition(manager.status.stringValue.contains("SECRET-diagnostic") && manager.phase == .idle)
        let verifyOutcome = try store.load().last?.outcome
        precondition(verifyOutcome == .failed)
        let persisted = try String(contentsOf: store.file, encoding: .utf8)
        precondition(!persisted.contains("SECRET") && !persisted.contains(source.path))
        // Runtime diagnostics may contain private paths; the default report exposes counts only.
        let savedVerification = Data(#"{"profiles":1,"sessionGroups":2,"incompleteGroups":0,"missingTranscripts":["SECRET-path"],"conversationMismatches":[],"auxiliaryMismatches":[],"duplicateMembers":[],"recordErrors":[{"record":"SECRET-record","profile":"SECRET-profile","reason":"invalid_record","detail":"SECRET-detail"}]}"#.utf8)
        try savedVerification.write(to: store.directory.appendingPathComponent("last-verification.json"))
        let reportText = manager.historyReportText()
        precondition(reportText.contains("2 vấn đề") && reportText.contains("lỗi bản ghi: 1") && !reportText.contains("SECRET"))
        manager.showReport()
        guard let sheet = manager.window.attachedSheet else { fatalError("report viewer not presented") }
        precondition(!manager.importButton.isEnabled && !manager.verifyButton.isEnabled && !manager.reportButton.isEnabled)
        let alert = sheet.contentView!
        func textViews(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        precondition(textViews(alert).contains { !$0.isEditable && $0.string.contains("Hoạt động gần đây") })
        manager.window.endSheet(sheet)
        await manager.afterHistorySheetDismissal()
        await manager.afterHistorySheetDismissal()
        precondition(manager.importButton.isEnabled && manager.reportButton.isEnabled)
        // Activity write failure stays separate from the original operation failure.
        try Data("broken".utf8).write(to: store.file)
        await manager.performHistoryVerification()
        precondition(manager.status.stringValue.contains("SECRET-diagnostic") && manager.activityWarning != nil)
        precondition(manager.historyReportText().contains("Không đọc được nhật ký"))
    }

    @MainActor static func testDetailsDismissal() async throws {
        let manager = Manager(); manager.prepareWindow(); manager.runtimeReady = true
        defer { NSStatusBar.system.removeStatusItem(manager.item); manager.window.close() }
        manager.setPhase(.idle)
        manager.showOperationDetails()
        guard let sheet = manager.window.attachedSheet else { fatalError("Details action did not present a sheet") }
        precondition(!manager.refresh.isEnabled)
        manager.window.endSheet(sheet)
        for _ in 0..<100 {
            if manager.refresh.isEnabled { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(manager.window.attachedSheet == nil)
        precondition(manager.refresh.isEnabled && manager.add.isEnabled, "Dismissed details sheet left controls disabled")
    }

    @MainActor static func testFailedSyncRefresh() async throws {
        let manager = Manager()
        manager.runtimeReady = true
        let recoveredStatus = Data(#"{"profiles":[],"pending":[],"issues":[{"code":"pending_recovery","detail":"Synthetic","blocking":true}],"lastSync":null}"#.utf8)
        var statusCalls = 0
        manager.request = { args in
            if args == ["status"] { statusCalls += 1; return recoveredStatus }
            throw BackendFailure(code: "fixture_failure", message: "Original failure", remediation: "Check recovery")
        }
        await manager.performSync()
        precondition(statusCalls == 1)
        precondition(manager.recoveryNeeded && !manager.sync.isEnabled)
        precondition(manager.status.stringValue.contains("Original failure"))
        precondition(manager.status.stringValue.contains("Phục hồi"))
        manager.runtimeReady = true
        manager.request = { _ in throw BackendFailure.incompatible }
        await manager.performSync()
        precondition(!manager.runtimeReady && !manager.add.isEnabled && manager.refresh.isEnabled)
    }

    @MainActor static func testSyncVerification() async throws {
        let manager = Manager()
        manager.runtimeReady = true
        var calls: [String] = []
        var failVerification = false
        var failSync = false
        var reopenCalls = 0
        manager.openRequest = { _ in reopenCalls += 1; return [] }
        manager.request = { args in
            calls.append(args[0])
            switch args[0] {
            case "check": return Data(#"{"busy":[],"errors":[],"running":[],"eligible":["a","b"],"pending":[]}"#.utf8)
            case "sync":
                if failSync { throw BackendFailure(code: "fixture_failure", message: "Sync failed before apply", remediation: "Inspect") }
                return Data(#"{"profiles":2,"sessions":4,"newBranches":0,"filesChanged":6,"backup":"fixture"}"#.utf8)
            case "verify":
                precondition(manager.phase == .verifying)
                if failVerification { throw BackendFailure(code: "verification_failed", message: "Verification failed", remediation: "Inspect backup") }
                return Data("{}".utf8)
            case "status": return Data(#"{"profiles":[],"pending":[],"issues":[],"lastSync":null}"#.utf8)
            default: fatalError("unexpected command")
            }
        }
        await manager.performSync()
        precondition(calls == ["check", "sync", "verify", "status"])
        precondition(manager.status.stringValue.contains("Đã đồng bộ 4 phiên"))
        precondition(reopenCalls == 1)
        reopenCalls = 0
        failVerification = true; calls.removeAll()
        await manager.performSync()
        precondition(calls == ["check", "sync", "verify", "status"])
        precondition(manager.status.stringValue.contains("Đã ghi đồng bộ nhưng chưa xác minh thành công"))
        precondition(manager.status.stringValue.contains("Verification failed"))
        precondition(reopenCalls == 0 && manager.status.stringValue.contains("Giữ các app đã đóng"))
        failVerification = false; failSync = true; calls.removeAll()
        await manager.performSync()
        precondition(calls == ["check", "sync", "status"])
        precondition(reopenCalls == 1, "Pre-write failure should still reopen previous apps")
    }

    @MainActor static func renderPreviews(_ manager: Manager, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager.signatureIssues = [:]; manager.runtimeReady = true
        let profiles = (0..<4).map { index in
            Profile(id: "fixture\(index)", name: ["Claude Công việc", "Claude Cá nhân", "Claude Nghiên cứu", "Magpie Local"][index], kind: index == 3 ? "magpie" : "claude", bundle: "/tmp/fixture\(index).app", bundleID: "test.fixture\(index)", ready: index != 2, running: index == 0, syncEnabled: index < 2, sessions: [125,84,0,32][index], archived: 0, health: [])
        }
        let report = Report(profiles: 2, sessions: 209, newBranches: 1, filesChanged: 18, backup: "fixture", warnings: 0, pending: [])
        let normal = Summary(profiles: profiles, pending: ["fixture2"], lastSync: report, issues: [])
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            manager.window.appearance = NSAppearance(named: appearance)
            manager.window.setContentSize(NSSize(width: 960, height: 820))
            manager.render(normal); manager.setPhase(.idle)
            try capture(manager.window, to: directory.appendingPathComponent("accounts-\(suffix).png"))
            manager.render(Summary(profiles: [], pending: [], lastSync: nil, issues: [])); manager.setPhase(.idle)
            try capture(manager.window, to: directory.appendingPathComponent("empty-\(suffix).png"))
        }
        manager.window.appearance = NSAppearance(named: .aqua)
        manager.window.setContentSize(NSSize(width: 820, height: 720))
        let many = (0..<15).map { index in
            Profile(id: "many\(index)", name: "Claude Nhóm phát triển sản phẩm và nghiên cứu — \(index + 1)", kind: "claude", bundle: "/tmp/many\(index).app", bundleID: "test.many\(index)", ready: true, running: false, syncEnabled: index < 2, sessions: 100 + index, archived: 0, health: [])
        }
        manager.render(Summary(profiles: many, pending: [], lastSync: report, issues: [])); manager.setPhase(.idle)
        manager.window.contentView?.layoutSubtreeIfNeeded()
        precondition(manager.rows.bounds.height > manager.scroll.contentView.bounds.height)
        manager.scroll.contentView.scroll(to: NSPoint(x: 0, y: 160))
        manager.scroll.reflectScrolledClipView(manager.scroll.contentView)
        let oldOffset = manager.scroll.contentView.bounds.origin.y
        manager.render(Summary(profiles: many, pending: [], lastSync: report, issues: []))
        precondition(abs(manager.scroll.contentView.bounds.origin.y - oldOffset) < 1)
        try capture(manager.window, to: directory.appendingPathComponent("many-small.png"))
        let recovery = HealthIssue(profile: nil, code: "pending_recovery", detail: "Fixture only", blocking: true)
        manager.render(Summary(profiles: profiles, pending: [], lastSync: report, issues: [recovery])); manager.setPhase(.idle)
        precondition(!manager.healthBanner.isHidden && !manager.sync.isEnabled)
        try capture(manager.window, to: directory.appendingPathComponent("recovery-small.png"))
        manager.render(normal); manager.setPhase(.syncing)
        precondition(!manager.add.isEnabled && !manager.sync.isEnabled)
        try capture(manager.window, to: directory.appendingPathComponent("syncing-small.png"))
    }

    @MainActor static func capture(_ window: NSWindow, to output: URL) throws {
        let view = window.contentView!
        view.wantsLayer = true
        view.layoutSubtreeIfNeeded()
        var png: Data?
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            png = bitmap.representation(using: .png, properties: [:])
        }
        try png!.write(to: output)
    }
}
