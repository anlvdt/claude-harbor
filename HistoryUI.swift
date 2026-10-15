import AppKit
import Foundation
import Darwin

// Deliberately closed vocabulary: never persist backend output, paths, names,
// session IDs, transcripts, or localized error descriptions in the activity log.
struct OperationSummary: Codable {
    enum Kind: String, Codable {
        case sync, historyImport, verify, repair, recovery, create, selection, open, health
        var title: String {
            switch self {
            case .sync: return L("Đồng bộ", "Sync")
            case .historyImport: return L("Nhập lịch sử", "Import History")
            case .verify: return L("Xác minh lịch sử", "Verify History")
            case .repair: return L("Sửa app", "Repair App")
            case .recovery: return L("Phục hồi", "Recover")
            case .create: return L("Thêm tài khoản", "Add Account")
            case .selection: return L("Lưu lựa chọn", "Save Selection")
            case .open: return L("Mở app", "Open App")
            case .health: return L("Kiểm tra app", "Check App")
            }
        }
    }
    enum Outcome: String, Codable {
        case succeeded, failed, cancelled, needsAttention
        var title: String {
            switch self {
            case .succeeded: return L("Hoàn tất", "Completed")
            case .failed: return L("Thất bại", "Failed")
            case .cancelled: return L("Đã hủy", "Cancelled")
            case .needsAttention: return L("Cần kiểm tra", "Needs attention")
            }
        }
    }
    let date: Date
    let kind: Kind
    let outcome: Outcome
    let profiles: Int?
    let sessions: Int?
    let filesChanged: Int?

    init(kind: Kind, outcome: Outcome, report: Report? = nil, date: Date = Date()) {
        self.date = date; self.kind = kind; self.outcome = outcome
        profiles = report.map { max(0, $0.profiles) }
        sessions = report.map { max(0, $0.sessions) }
        filesChanged = report.map { max(0, $0.filesChanged) }
    }
}

struct OperationActivityStore {
    static let limit = 100
    static let byteLimit = 128 * 1024
    let directory: URL
    var file: URL { directory.appendingPathComponent("ui-activity.json") }

    // Refuse symlinked logs and bound reads even if another process replaces a file.
    static func readBounded(_ url: URL, limit: Int) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= limit else { throw CocoaError(.fileReadTooLarge) }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw CocoaError(.fileReadTooLarge) }
        return data
    }
    func load() throws -> [OperationSummary] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return Array(try JSONDecoder().decode([OperationSummary].self,
                    from: Self.readBounded(file, limit: Self.byteLimit)).suffix(Self.limit))
    }
    func append(_ entry: OperationSummary) throws {
        var entries = try load()
        entries.append(entry); entries = Array(entries.suffix(Self.limit))
        let data = try JSONEncoder().encode(entries)
        guard data.count <= Self.byteLimit else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let temporary = directory.appendingPathComponent(".ui-activity-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(temporary.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

struct VerificationSummary: Decodable {
    let profiles: Int
    let sessionGroups: Int
    let incompleteGroups: Int
    let missingTranscripts: [String]
    let conversationMismatches: [String]
    let auxiliaryMismatches: [String]
    let duplicateMembers: [String]
    struct RecordError: Decodable {
        let record: String?
        let profile: String?
        let reason: String?
        let detail: String?
    }
    let recordErrors: [RecordError]
    var issueCount: Int {
        incompleteGroups + missingTranscripts.count + conversationMismatches.count + auxiliaryMismatches.count + duplicateMembers.count + recordErrors.count
    }
    var text: String {
        L("\(profiles) tài khoản · \(sessionGroups) nhóm phiên · \(issueCount) vấn đề\nThiếu nhóm: \(incompleteGroups); thiếu bản ghi: \(missingTranscripts.count); hội thoại khác: \(conversationMismatches.count); tệp phụ khác: \(auxiliaryMismatches.count); trùng thành viên: \(duplicateMembers.count); lỗi bản ghi: \(recordErrors.count).", "\(profiles) accounts · \(sessionGroups) session groups · \(issueCount) issues\nMissing groups: \(incompleteGroups); missing transcripts: \(missingTranscripts.count); conversation mismatches: \(conversationMismatches.count); auxiliary file mismatches: \(auxiliaryMismatches.count); duplicate members: \(duplicateMembers.count); record errors: \(recordErrors.count).")
    }
}

enum HistoryImportSource {
    static func validate(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let source = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        let projects = source.appendingPathComponent("projects")
        guard FileManager.default.fileExists(atPath: projects.path, isDirectory: &isDirectory),
              isDirectory.boolValue, FileManager.default.isReadableFile(atPath: projects.path) else {
            throw NSError(domain: "HistoryImport", code: 1, userInfo: [NSLocalizedDescriptionKey:
                L("Chọn thư mục cấu hình Claude Code có thư mục projects đọc được (thường là ~/.claude), không chọn một tệp transcript hoặc thư mục projects.", "Choose a Claude Code configuration folder with a readable projects folder (usually ~/.claude), rather than a transcript file or the projects folder itself.")])
        }
        return source
    }
    static func confirmation(source: URL, targets: [Profile], desktopRoot: URL? = nil) -> String {
        L("Nguồn: \(source.path)\nMetadata Desktop: \(desktopRoot?.path ?? L("Không dùng (mặc định)", "Not used (default)"))\n\nNhập vào \(targets.count) tài khoản đã chọn:\n", "Source: \(source.path)\nDesktop metadata: \(desktopRoot?.path ?? L("Không dùng (mặc định)", "Not used (default)"))\n\nImport into \(targets.count) selected accounts:\n") + targets.map(\.name).joined(separator: "\n") +
        L("\n\nLịch sử Code local từ nguồn này sẽ được sao chép và hợp nhất vào các tài khoản trên. Harbor giữ nhánh khác nhau và tạo bản sao lưu trước khi ghi. Nguồn không bị chỉnh sửa. Không nhập đăng nhập, Chat web, Cowork hoặc dữ liệu cloud.\n\nĐóng Claude và công cụ đang ghi nguồn trước khi tiếp tục. Không dùng nguồn thuộc tài khoản Harbor; hãy dùng Đồng bộ cho các tài khoản đó.", "\n\nLocal Code history from this source will be copied and merged into the accounts above. Harbor preserves different branches and creates a backup before writing. The source is not modified. Sign-ins, web Chat, Cowork, and cloud data are not imported.\n\nClose Claude and any tools writing to the source before continuing. Do not use a source belonging to a Harbor account; use Sync for those accounts.")
    }
}

@MainActor extension Manager {
    var historyTargets: [Profile] { profiles.filter { $0.syncEnabled && $0.ready } }
    var historyActionAvailable: Bool {
        !working && runtimeReady && !recoveryNeeded && window?.attachedSheet == nil &&
        !historyTargets.isEmpty && !profiles.contains(where: \.running) &&
        !historyTargets.contains { $0.health.contains(where: \.blocking) }
    }
    func recordActivity(_ kind: OperationSummary.Kind, _ outcome: OperationSummary.Outcome, report: Report? = nil) {
        guard let activityStore else { return }
        do { try activityStore.append(OperationSummary(kind: kind, outcome: outcome, report: report)); activityWarning = nil }
        catch { activityWarning = L("Không lưu được nhật ký hoạt động. Báo cáo runtime và bản sao lưu vẫn nằm trong thư mục Harbor.", "Could not save the activity log. Runtime reports and backups remain in the Harbor folder.") }
    }
    // AppKit may clear attachedSheet after its completion handler returns.
    // Advance to the next main-queue turn before presenting or guarding again.
    func afterHistorySheetDismissal() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
    func historyFolderPanel(desktop: Bool = false) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = desktop ? L("Chọn metadata Claude Desktop", "Choose Claude Desktop Metadata") : L("Chọn nguồn lịch sử Claude Code", "Choose a Claude Code History Source")
        panel.message = desktop ? L("Chọn thư mục dữ liệu Desktop tương ứng với nguồn Code, để giữ liên kết chuỗi phiên cũ.", "Choose the Desktop data folder matching the Code source to preserve links between earlier sessions.") : L("Chọn thư mục cấu hình chứa projects (thường là ~/.claude).", "Choose the configuration folder containing projects (usually ~/.claude).")
        panel.prompt = L("Chọn thư mục", "Choose Folder")
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        panel.showsHiddenFiles = true; panel.resolvesAliases = true
        return panel
    }
    @objc func importHistory() {
        guard historyActionAvailable else { return }
        setPhase(.configuring)
        Task {
            do {
                let panel = historyFolderPanel()
                let response = await panel.beginSheetModal(for: window)
                await afterHistorySheetDismissal()
                guard response == .OK, let url = panel.url else { cancelHistoryImport(); return }
                let source = try HistoryImportSource.validate(url)
                let metadata = NSAlert(); metadata.messageText = L("Dùng metadata Claude Desktop?", "Use Claude Desktop metadata?")
                metadata.informativeText = L("Không dùng là mặc định. Nếu có thư mục dữ liệu Desktop tương ứng với nguồn Code, bạn có thể chọn để giữ liên kết các phiên trước trong cùng chuỗi. Thư mục metadata chỉ được đọc.", "Metadata is unused by default. If you have a Desktop data folder matching the Code source, you can select it to preserve links to earlier sessions in the same chain. The metadata folder is read-only.")
                metadata.addButton(withTitle: L("Không dùng metadata", "Skip Metadata"))
                metadata.addButton(withTitle: L("Chọn thư mục Desktop…", "Choose Desktop Folder…"))
                metadata.addButton(withTitle: L("Hủy nhập", "Cancel Import"))
                let metadataChoice = await metadata.beginSheetModal(for: window)
                await afterHistorySheetDismissal()
                if metadataChoice == .alertThirdButtonReturn { cancelHistoryImport(); return }
                var desktopRoot: URL?
                if metadataChoice == .alertSecondButtonReturn {
                    let desktop = historyFolderPanel(desktop: true)
                    let choice = await desktop.beginSheetModal(for: window)
                    await afterHistorySheetDismissal()
                    guard choice == .OK, let folder = desktop.url else { cancelHistoryImport(); return }
                    let selected = folder.standardizedFileURL.resolvingSymlinksInPath()
                    let values = try selected.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
                    guard values.isDirectory == true, values.isReadable == true else { throw CocoaError(.fileReadNoPermission) }
                    desktopRoot = selected
                }
                let targets = historyTargets
                let alert = NSAlert(); alert.messageText = L("Nhập và chia sẻ lịch sử Code?", "Import and share Code history?")
                alert.informativeText = HistoryImportSource.confirmation(source: source, targets: targets, desktopRoot: desktopRoot)
                alert.addButton(withTitle: L("Hủy", "Cancel")); alert.addButton(withTitle: L("Nhập lịch sử", "Import History"))
                let choice = await alert.beginSheetModal(for: window)
                await afterHistorySheetDismissal()
                guard choice == .alertSecondButtonReturn else { cancelHistoryImport(); return }
                setPhase(.idle)
                await performHistoryImport(source: source, targetIDs: targets.map(\.id), desktopRoot: desktopRoot)
            } catch { status.stringValue = error.localizedDescription; setPhase(.idle) }
        }
    }
    func cancelHistoryImport() {
        status.stringValue = L("Đã hủy nhập lịch sử.", "History import cancelled."); setPhase(.idle)
    }
    func performHistoryImport(source: URL, targetIDs: [String], desktopRoot: URL? = nil) async {
        guard historyActionAvailable, !targetIDs.isEmpty,
              Set(targetIDs) == Set(historyTargets.map(\.id)) else { return }
        setPhase(.importing)
        var applied = false
        var imported: Report?
        do {
            let source = try HistoryImportSource.validate(source)
            var arguments = ["import", "--source", source.path, "--to", targetIDs.joined(separator: ",")]
            if let desktopRoot { arguments += ["--desktop-root", desktopRoot.path] }
            let report = try JSONDecoder().decode(Report.self, from: try await request(arguments))
            imported = report; applied = true
            setPhase(.verifying)
            _ = try await request(["verify"])
            let refreshed = await load(showSummary: false)
            status.stringValue = L("Đã nhập \(report.sessions) phiên vào \(report.profiles) tài khoản; \(report.filesChanged) tệp cập nhật. Xem Báo cáo & sao lưu.", "Imported \(report.sessions) sessions into \(report.profiles) accounts; \(report.filesChanged) files updated. See Reports & Backups.")
            if (report.warnings ?? 0) > 0 { status.stringValue += L(" Có \(report.warnings!) cảnh báo; kiểm tra báo cáo trước khi tiếp tục.", " \(report.warnings!) warnings; check the report before continuing.") }
            if !refreshed { status.stringValue += L("\nChưa làm mới được; bấm Làm mới trước thao tác tiếp theo.", "\nCould not refresh; click Refresh before the next operation.") }
            recordActivity(.historyImport, (report.warnings ?? 0) > 0 || !refreshed ? .needsAttention : .succeeded, report: report)
        } catch {
            let message = error.localizedDescription
            let refreshed = await load(showSummary: false)
            status.stringValue = (applied ? L("Đã ghi nhập nhưng chưa xác minh thành công: ", "Import was written but verification did not succeed: ") : L("Chưa hoàn tất nhập lịch sử: ", "History import did not finish: ")) + message
            if !refreshed { status.stringValue += L("\nChưa làm mới được; bấm Làm mới.", "\nCould not refresh; click Refresh.") }
            else if recoveryNeeded { status.stringValue += L("\nCần phục hồi: đóng các profile rồi chọn Kiểm tra → Phục hồi.", "\nRecovery required: close the profiles, then choose Check → Recover.") }
            recordActivity(.historyImport, applied ? .needsAttention : .failed, report: imported)
        }
        setPhase(.idle)
    }
    @objc func verifyHistory() {
        guard historyActionAvailable else { return }
        setPhase(.verifying)
        Task { await performHistoryVerification(started: true) }
    }
    func performHistoryVerification(started: Bool = false) async {
        guard started ? phase == .verifying : historyActionAvailable else { return }
        setPhase(.verifying)
        do {
            let result = try JSONDecoder().decode(VerificationSummary.self, from: try await request(["verify"]))
            let refreshed = await load(showSummary: false)
            status.stringValue = L("Đã xác minh lịch sử. ", "History verified. ") + result.text
            if !refreshed { status.stringValue += L("\nChưa làm mới được; bấm Làm mới.", "\nCould not refresh; click Refresh.") }
            recordActivity(.verify, result.issueCount == 0 ? .succeeded : .needsAttention)
        } catch {
            let message = error.localizedDescription
            let refreshed = await load(showSummary: false)
            status.stringValue = L("Chưa xác minh thành công: ", "Verification did not succeed: ") + message
            if !refreshed { status.stringValue += L("\nChưa làm mới được; bấm Làm mới.", "\nCould not refresh; click Refresh.") }
            else if recoveryNeeded { status.stringValue += L("\nCần phục hồi trước thao tác tiếp theo.", "\nRecovery is required before the next operation.") }
            recordActivity(.verify, .failed)
        }
        setPhase(.idle)
    }
    func historyReportText() -> String {
        var sections = [L("Báo cáo chỉ đọc · Lịch sử Code local", "Read-only Report · Local Code History")]
        if let report = latestSummary?.lastSync {
            sections.append(L("Lần đồng bộ / nhập gần nhất\n\(report.profiles) tài khoản · \(report.sessions) phiên · \(report.filesChanged) tệp cập nhật · \(report.newBranches) nhánh giữ thêm · \(report.warnings ?? 0) cảnh báo.\nBản sao lưu: \(report.backup.isEmpty ? L("chưa có", "none yet") : L("đã lưu trong thư mục Harbor", "saved in the Harbor folder")).", "Latest sync / import\n\(report.profiles) accounts · \(report.sessions) sessions · \(report.filesChanged) files updated · \(report.newBranches) additional branches preserved · \(report.warnings ?? 0) warnings.\nBackup: \(report.backup.isEmpty ? L("chưa có", "none yet") : L("đã lưu trong thư mục Harbor", "saved in the Harbor folder"))."))
        } else { sections.append(L("Chưa có báo cáo đồng bộ / nhập.", "No sync / import report yet.")) }
        if let activityStore {
            let verificationFile = activityStore.directory.appendingPathComponent("last-verification.json")
            if FileManager.default.fileExists(atPath: verificationFile.path) {
                do {
                    let report = try JSONDecoder().decode(VerificationSummary.self, from: OperationActivityStore.readBounded(verificationFile, limit: 1024 * 1024))
                    sections.append(L("Xác minh đã lưu (phản ánh thời điểm chạy, có thể cũ)\n", "Saved verification (reflects the time it ran and may be outdated)\n") + report.text)
                } catch { sections.append(L("Không đọc được báo cáo xác minh đã lưu.", "Could not read the saved verification report.")) }
            } else { sections.append(L("Chưa có báo cáo xác minh đã lưu.", "No saved verification report yet.")) }
            do {
                let entries = try activityStore.load()
                let formatter = DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .short
                formatter.locale = Locale(identifier: L10n.language.rawValue)
                sections.append(L("Hoạt động gần đây (tối đa \(OperationActivityStore.limit) mục)\n", "Recent activity (up to \(OperationActivityStore.limit) entries)\n") + (entries.isEmpty ? L("Chưa có hoạt động được lưu.", "No saved activity yet.") : entries.reversed().map { entry in
                    var line = formatter.string(from: entry.date) + " · " + entry.kind.title + " · " + entry.outcome.title
                    if let profiles = entry.profiles, let sessions = entry.sessions, let files = entry.filesChanged {
                        line += L(" · \(profiles) tài khoản, \(sessions) phiên, \(files) tệp", " · \(profiles) accounts, \(sessions) sessions, \(files) files")
                    }
                    return line
                }.joined(separator: "\n")))
            } catch { sections.append(L("Không đọc được nhật ký hoạt động; nhật ký được giữ nguyên để kiểm tra.", "Could not read the activity log; it has been preserved for inspection.")) }
        }
        if let activityWarning { sections.append(activityWarning) }
        sections.append(L("Nhật ký chỉ lưu thời gian, loại thao tác, kết quả và số lượng. Không lưu đường dẫn, tên tài khoản, nội dung hội thoại hoặc lỗi thô. Mở thư mục để xem báo cáo runtime chi tiết và bản sao lưu; các tệp đó có thể chứa thông tin riêng tư.", "The log stores only timestamps, operation types, outcomes, and counts. It does not store paths, account names, conversation content, or raw errors. Open the folder to view detailed runtime reports and backups; those files may contain private information."))
        return sections.joined(separator: "\n\n")
    }
    @objc func showReport() {
        guard !working, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = L("Báo cáo & hoạt động", "Reports & Activity")
        alert.addButton(withTitle: L("Đóng", "Close")); alert.addButton(withTitle: L("Mở thư mục báo cáo & sao lưu", "Open Reports & Backups Folder"))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 360))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false; text.isSelectable = true; text.font = .systemFont(ofSize: 13)
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.isHorizontallyResizable = false; text.isVerticallyResizable = true
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.string = historyReportText(); scroll.documentView = text; alert.accessoryView = scroll
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn, let directory = self.activityStore?.directory { NSWorkspace.shared.open(directory) }
            DispatchQueue.main.async { [weak self] in self?.updateControls() }
        }
        updateControls()
    }
}
