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
            case .sync: return "Đồng bộ"
            case .historyImport: return "Nhập lịch sử"
            case .verify: return "Xác minh lịch sử"
            case .repair: return "Sửa app"
            case .recovery: return "Phục hồi"
            case .create: return "Thêm tài khoản"
            case .selection: return "Lưu lựa chọn"
            case .open: return "Mở app"
            case .health: return "Kiểm tra app"
            }
        }
    }
    enum Outcome: String, Codable {
        case succeeded, failed, cancelled, needsAttention
        var title: String {
            switch self {
            case .succeeded: return "Hoàn tất"
            case .failed: return "Thất bại"
            case .cancelled: return "Đã hủy"
            case .needsAttention: return "Cần kiểm tra"
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
        "\(profiles) tài khoản · \(sessionGroups) nhóm phiên · \(issueCount) vấn đề\nThiếu nhóm: \(incompleteGroups); thiếu bản ghi: \(missingTranscripts.count); hội thoại khác: \(conversationMismatches.count); tệp phụ khác: \(auxiliaryMismatches.count); trùng thành viên: \(duplicateMembers.count); lỗi bản ghi: \(recordErrors.count)."
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
                "Chọn thư mục cấu hình Claude Code có thư mục projects đọc được (thường là ~/.claude), không chọn một tệp transcript hoặc thư mục projects."])
        }
        return source
    }
    static func confirmation(source: URL, targets: [Profile], desktopRoot: URL? = nil) -> String {
        "Nguồn: \(source.path)\nMetadata Desktop: \(desktopRoot?.path ?? "Không dùng (mặc định)")\n\nNhập vào \(targets.count) tài khoản đã chọn:\n" + targets.map(\.name).joined(separator: "\n") +
        "\n\nLịch sử Code local từ nguồn này sẽ được sao chép và hợp nhất vào các tài khoản trên. Harbor giữ nhánh khác nhau và tạo bản sao lưu trước khi ghi. Nguồn không bị chỉnh sửa. Không nhập đăng nhập, Chat web, Cowork hoặc dữ liệu cloud.\n\nĐóng Claude và công cụ đang ghi nguồn trước khi tiếp tục. Không dùng nguồn thuộc tài khoản Harbor; hãy dùng Đồng bộ cho các tài khoản đó."
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
        catch { activityWarning = "Không lưu được nhật ký hoạt động. Báo cáo runtime và bản sao lưu vẫn nằm trong thư mục Harbor." }
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
        panel.title = desktop ? "Chọn metadata Claude Desktop" : "Chọn nguồn lịch sử Claude Code"
        panel.message = desktop ? "Chọn thư mục dữ liệu Desktop tương ứng với nguồn Code, để giữ liên kết chuỗi phiên cũ." : "Chọn thư mục cấu hình chứa projects (thường là ~/.claude)."
        panel.prompt = "Chọn thư mục"
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
                let metadata = NSAlert(); metadata.messageText = "Dùng metadata Claude Desktop?"
                metadata.informativeText = "Không dùng là mặc định. Nếu có thư mục dữ liệu Desktop tương ứng với nguồn Code, bạn có thể chọn để giữ liên kết các phiên trước trong cùng chuỗi. Thư mục metadata chỉ được đọc."
                metadata.addButton(withTitle: "Không dùng metadata")
                metadata.addButton(withTitle: "Chọn thư mục Desktop…")
                metadata.addButton(withTitle: "Hủy nhập")
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
                let alert = NSAlert(); alert.messageText = "Nhập và chia sẻ lịch sử Code?"
                alert.informativeText = HistoryImportSource.confirmation(source: source, targets: targets, desktopRoot: desktopRoot)
                alert.addButton(withTitle: "Hủy"); alert.addButton(withTitle: "Nhập lịch sử")
                let choice = await alert.beginSheetModal(for: window)
                await afterHistorySheetDismissal()
                guard choice == .alertSecondButtonReturn else { cancelHistoryImport(); return }
                setPhase(.idle)
                await performHistoryImport(source: source, targetIDs: targets.map(\.id), desktopRoot: desktopRoot)
            } catch { status.stringValue = error.localizedDescription; setPhase(.idle) }
        }
    }
    func cancelHistoryImport() {
        status.stringValue = "Đã hủy nhập lịch sử."; setPhase(.idle)
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
            status.stringValue = "Đã nhập \(report.sessions) phiên vào \(report.profiles) tài khoản; \(report.filesChanged) tệp cập nhật. Xem Báo cáo & sao lưu."
            if (report.warnings ?? 0) > 0 { status.stringValue += " Có \(report.warnings!) cảnh báo; kiểm tra báo cáo trước khi tiếp tục." }
            if !refreshed { status.stringValue += "\nChưa làm mới được; bấm Làm mới trước thao tác tiếp theo." }
            recordActivity(.historyImport, (report.warnings ?? 0) > 0 || !refreshed ? .needsAttention : .succeeded, report: report)
        } catch {
            let message = error.localizedDescription
            let refreshed = await load(showSummary: false)
            status.stringValue = (applied ? "Đã ghi nhập nhưng chưa xác minh thành công: " : "Chưa hoàn tất nhập lịch sử: ") + message
            if !refreshed { status.stringValue += "\nChưa làm mới được; bấm Làm mới." }
            else if recoveryNeeded { status.stringValue += "\nCần phục hồi: đóng các profile rồi chọn Kiểm tra → Phục hồi." }
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
            status.stringValue = "Đã xác minh lịch sử. " + result.text
            if !refreshed { status.stringValue += "\nChưa làm mới được; bấm Làm mới." }
            recordActivity(.verify, result.issueCount == 0 ? .succeeded : .needsAttention)
        } catch {
            let message = error.localizedDescription
            let refreshed = await load(showSummary: false)
            status.stringValue = "Chưa xác minh thành công: " + message
            if !refreshed { status.stringValue += "\nChưa làm mới được; bấm Làm mới." }
            else if recoveryNeeded { status.stringValue += "\nCần phục hồi trước thao tác tiếp theo." }
            recordActivity(.verify, .failed)
        }
        setPhase(.idle)
    }
    func historyReportText() -> String {
        var sections = ["Báo cáo chỉ đọc · Lịch sử Code local"]
        if let report = latestSummary?.lastSync {
            sections.append("Lần đồng bộ / nhập gần nhất\n\(report.profiles) tài khoản · \(report.sessions) phiên · \(report.filesChanged) tệp cập nhật · \(report.newBranches) nhánh giữ thêm · \(report.warnings ?? 0) cảnh báo.\nBản sao lưu: \(report.backup.isEmpty ? "chưa có" : "đã lưu trong thư mục Harbor").")
        } else { sections.append("Chưa có báo cáo đồng bộ / nhập.") }
        if let activityStore {
            let verificationFile = activityStore.directory.appendingPathComponent("last-verification.json")
            if FileManager.default.fileExists(atPath: verificationFile.path) {
                do {
                    let report = try JSONDecoder().decode(VerificationSummary.self, from: OperationActivityStore.readBounded(verificationFile, limit: 1024 * 1024))
                    sections.append("Xác minh đã lưu (phản ánh thời điểm chạy, có thể cũ)\n" + report.text)
                } catch { sections.append("Không đọc được báo cáo xác minh đã lưu.") }
            } else { sections.append("Chưa có báo cáo xác minh đã lưu.") }
            do {
                let entries = try activityStore.load()
                let formatter = DateFormatter(); formatter.dateStyle = .short; formatter.timeStyle = .short
                sections.append("Hoạt động gần đây (tối đa \(OperationActivityStore.limit) mục)\n" + (entries.isEmpty ? "Chưa có hoạt động được lưu." : entries.reversed().map { entry in
                    var line = formatter.string(from: entry.date) + " · " + entry.kind.title + " · " + entry.outcome.title
                    if let profiles = entry.profiles, let sessions = entry.sessions, let files = entry.filesChanged {
                        line += " · \(profiles) tài khoản, \(sessions) phiên, \(files) tệp"
                    }
                    return line
                }.joined(separator: "\n")))
            } catch { sections.append("Không đọc được nhật ký hoạt động; nhật ký được giữ nguyên để kiểm tra.") }
        }
        if let activityWarning { sections.append(activityWarning) }
        sections.append("Nhật ký chỉ lưu thời gian, loại thao tác, kết quả và số lượng. Không lưu đường dẫn, tên tài khoản, nội dung hội thoại hoặc lỗi thô. Mở thư mục để xem báo cáo runtime chi tiết và bản sao lưu; các tệp đó có thể chứa thông tin riêng tư.")
        return sections.joined(separator: "\n\n")
    }
    @objc func showReport() {
        guard !working, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "Báo cáo & hoạt động"
        alert.addButton(withTitle: "Đóng"); alert.addButton(withTitle: "Mở thư mục báo cáo & sao lưu")
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
