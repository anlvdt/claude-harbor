import AppKit
import Foundation
import Darwin

struct Profile: Decodable, Sendable {
    let id: String; let name: String; let kind: String; let bundle: String; let bundleID: String
    let ready: Bool; let running: Bool; let syncEnabled: Bool; let sessions: Int; let archived: Int
    var health: [HealthIssue]
}
struct Summary: Decodable { let profiles: [Profile]; let pending: [String]; let lastSync: Report?; let issues: [HealthIssue] }
struct Check: Decodable {
    let busy: [String]; let errors: [String]; let running: [String]; let eligible: [String]; let pending: [String]
    struct BusyDetail: Decodable { let profile: String; let reason: String; let title: String? }
    let busyDetails: [BusyDetail]?
    func busyDescription(profiles: [Profile]) -> String {
        guard let busyDetails, busyDetails.count == busy.count else {
            return L10n.language == .english ? "Waiting for active sessions to finish." : busy.joined(separator: "; ")
        }
        return busyDetails.map { detail in
            let name = profiles.first { $0.id == detail.profile }?.name ?? L("Tài khoản", "Account")
            let reason: String
            switch detail.reason {
            case "reply_in_progress": reason = detail.title ?? L("đang trả lời", "reply in progress")
            case "session_writing": reason = L("đang ghi phiên, chờ lưu xong", "session is being written; waiting for it to save")
            default: reason = L("chưa kiểm tra an toàn được phiên đang chạy", "cannot safely inspect the active session")
            }
            return name + ": " + reason
        }.joined(separator: "; ")
    }
}
struct Report: Decodable { let profiles: Int; let sessions: Int; let newBranches: Int; let filesChanged: Int; let backup: String; let warnings: Int?; let pending: [String]? }
struct HealthIssue: Decodable {
    let profile: String?; let code: String; let detail: String; let blocking: Bool
    var displayText: String {
        switch code {
        case "clone_layout_changed", "missing_binary", "clone_version_changed", "launcher_modified", "invalid_signature", "unreadable_clone":
            return L("Đóng các bản Claude rồi chọn Sửa để khôi phục app.", "Close the Claude apps, then choose Repair to restore the app.")
        case "source_version_changed": return L("Claude gốc đã cập nhật; có thể sửa để cập nhật bản riêng.", "Official Claude has updated; repair to update this copy.")
        case "source_unavailable": return L("Chưa tìm thấy Claude gốc để tạo hoặc sửa bản riêng.", "Official Claude is unavailable for creating or repairing copies.")
        case "pending_recovery", "interrupted_clone_repair": return L("Có giao dịch chưa hoàn tất; đóng các profile rồi phục hồi.", "An operation is unfinished; close the profiles, then recover it.")
        case "recovery_unreadable": return L("Không đọc được nhật ký; giữ lại bản sao lưu và kiểm tra dữ liệu.", "The journal cannot be read; keep the backups and inspect your data.")
        default: return L("Có vấn đề cần kiểm tra [\(code)].", "An issue needs attention [\(code)].")
        }
    }
}
struct HealthReport: Decodable { let issues: [HealthIssue]; let ok: Bool }
struct BackendResult: Sendable { let status: Int32; let data: Data; let error: String }
struct BackendFailure: Decodable, LocalizedError {
    let code: String
    let message: String
    let remediation: String
    var errorDescription: String? { L10n.backendError(code: code, message: message, remediation: remediation) }
    static let incompatible = BackendFailure(code: "protocol_incompatible", message: "Giao diện và runtime không tương thích.", remediation: "Mở lại Harbor từ cùng một bản cài đặt để cập nhật runtime.")
}
struct RuntimeCapabilities: Decodable {
    let protocolVersion: Int
    let features: [String]
    var isCompatible: Bool {
        protocolVersion == 1 && Set(["structured_errors", "profile_health", "recovery_status"]).isSubset(of: Set(features))
    }
}
private struct DesktopResponseHeader: Decodable {
    let protocolVersion: Int
    let ok: Bool
    let error: BackendFailure?
}
func decodeDesktopResponse(_ data: Data, status: Int32) throws -> Data {
    guard let header = try? JSONDecoder().decode(DesktopResponseHeader.self, from: data), header.protocolVersion == 1,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BackendFailure.incompatible }
    if !header.ok {
        guard status != 0, let error = header.error, object["result"] == nil else { throw BackendFailure.incompatible }
        throw error
    }
    guard status == 0, object["error"] == nil, let result = object["result"] as? [String: Any] else { throw BackendFailure.incompatible }
    return try JSONSerialization.data(withJSONObject: result)
}

enum OperationPhase {
    case idle, starting, loading, selecting, opening, configuring, creating, checking, waiting, closing, syncing, importing, verifying, reopening, repairing, recovering
    var isBusy: Bool { self != .idle }
    var canCancel: Bool { self == .waiting }
    var title: String {
        switch self {
        case .idle: return L("Sẵn sàng", "Ready")
        case .starting: return L("Đang khởi tạo…", "Starting…")
        case .loading: return L("Đang làm mới…", "Refreshing…")
        case .selecting: return L("Đang lưu lựa chọn…", "Saving selection…")
        case .opening: return L("Đang mở Claude…", "Opening Claude…")
        case .configuring: return L("Thêm tài khoản", "Add account")
        case .creating: return L("Đang tạo bản Claude…", "Creating Claude copy…")
        case .checking: return L("Đang kiểm tra…", "Checking…")
        case .waiting: return L("Đang chờ trả lời xong…", "Waiting for replies…")
        case .closing: return L("Đang đóng các bản Claude…", "Closing Claude apps…")
        case .syncing: return L("Đang sao lưu và đồng bộ…", "Backing up and syncing…")
        case .importing: return L("Đang sao lưu và nhập lịch sử…", "Backing up and importing history…")
        case .verifying: return L("Đang xác minh lịch sử…", "Verifying history…")
        case .reopening: return L("Đang mở lại các app…", "Reopening apps…")
        case .repairing: return L("Đang sửa bản Claude…", "Repairing Claude copy…")
        case .recovering: return L("Đang phục hồi giao dịch…", "Recovering operation…")
        }
    }
}
let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
let legacyRoot = support.appendingPathComponent("ClaudeThreeDesktop")
let root = FileManager.default.fileExists(atPath: legacyRoot.appendingPathComponent("profiles.json").path) ? legacyRoot : support.appendingPathComponent("ClaudeHarbor")

final class BackendCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = [Data(), Data()]
    private var failure: String?
    private var finished = false
    let process = Process()
    var hasFailed: Bool {
        lock.lock(); defer { lock.unlock() }
        return failure != nil
    }
    func append(_ data: Data, stream: Int, limit: Int) {
        lock.lock()
        let exceeded = buffers[stream].count + data.count > limit
        if !exceeded { buffers[stream].append(data) }
        lock.unlock()
        if exceeded { stop("Backend output exceeded its limit; recovery may be required.") }
    }
    func stop(_ message: String) {
        lock.lock(); if finished { lock.unlock(); return }; if failure == nil { failure = message }; lock.unlock()
        if process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
    func result() -> BackendResult {
        lock.lock(); defer { lock.unlock() }; finished = true
        return BackendResult(status: failure == nil ? process.terminationStatus : -1,
                             data: buffers[0], error: failure ?? String(decoding: buffers[1], as: UTF8.self))
    }
}

func executePython(_ arguments: [String], timeout: TimeInterval = 600, desktopProtocol: Bool = false, environment: [String: String] = [:]) async throws -> Data {
    let result: BackendResult = try await withCheckedThrowingContinuation { continuation in
        let capture = BackendCapture(); let process = capture.process
        let output = Pipe(); let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, value in value }
        process.standardOutput = output; process.standardError = errors
        let readers = DispatchGroup()
        readers.enter(); readers.enter()
        process.terminationHandler = { _ in
            readers.notify(queue: .global()) {
                process.terminationHandler = nil
                continuation.resume(returning: capture.result())
            }
        }
        do { try process.run() } catch {
            process.terminationHandler = nil
            readers.leave(); readers.leave()
            continuation.resume(throwing: error); return
        }
        output.fileHandleForWriting.closeFile(); errors.fileHandleForWriting.closeFile()
        for (index, handle) in [output.fileHandleForReading, errors.fileHandleForReading].enumerated() {
            DispatchQueue.global().async {
                defer { handle.closeFile(); readers.leave() }
                var buffer = [UInt8](repeating: 0, count: 65536)
                while !capture.hasFailed {
                    // Poll lets a timeout stop draining even if a descendant
                    // inherited the pipe after the direct Python child exited.
                    var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                    let available = Darwin.poll(&descriptor, 1, 100)
                    if available == 0 { continue }
                    if available < 0 {
                        if errno == EINTR { continue }
                        capture.stop("Backend output could not be read."); break
                    }
                    let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR || errno == EAGAIN { continue }
                        capture.stop("Backend output could not be read."); break
                    }
                    capture.append(Data(buffer.prefix(count)), stream: index, limit: index == 0 ? 8 * 1024 * 1024 : 1024 * 1024)
                }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak capture] in
            capture?.stop("Backend timed out; the next sync will recover unfinished writes.")
        }
    }
    if desktopProtocol && result.status != -1 { return try decodeDesktopResponse(result.data, status: result.status) }
    guard result.status == 0 else { throw NSError(domain: "ClaudeHarbor", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.error]) }
    return result.data
}

func backend(_ arguments: [String], directory: URL = root, environment: [String: String] = [:]) async throws -> Data {
    try await executePython([directory.appendingPathComponent("manager.py").path, "--desktop-api", "1"] + arguments, desktopProtocol: true, environment: environment)
}

@MainActor final class Manager: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    // NSApplication.delegate is weak. Retain only the currently displayed manager.
    static var active: Manager?
    var window: NSWindow!
    var profiles: [Profile] = []
    let status = NSTextField(wrappingLabelWithString: L("Đang đọc các profile…", "Loading profiles…"))
    let footer = NSTextField(wrappingLabelWithString: "")
    let sync = NSButton(title: L("Đồng bộ đã chọn", "Sync selected"), target: nil, action: nil)
    let add = NSButton(title: L("Thêm tài khoản", "Add account"), target: nil, action: nil)
    let openAll = NSButton(title: L("Mở tất cả", "Open all"), target: nil, action: nil)
    let refresh = NSButton(title: L("Làm mới", "Refresh"), target: nil, action: nil)
    let health = NSButton(title: L("Kiểm tra", "Check health"), target: nil, action: nil)
    let progress = NSProgressIndicator()
    let menuStatus = NSMenuItem(title: L("Đang khởi tạo…", "Starting…"), action: nil, keyEquivalent: "")
    let rows = FlippedStackView()
    let scroll = NSScrollView()
    let emptyState = NSView()
    let overviewLabel = HarborUI.label(L("Tài khoản của bạn", "Your accounts"), size: 13, secondary: true)
    let selectionLabel = HarborUI.label(L("Chưa chọn tài khoản", "No accounts selected"), size: 12, weight: .medium, secondary: true)
    let operationHeading = HarborUI.label(L("Hoạt động gần nhất", "Latest activity"), size: 12, weight: .semibold)
    let healthBanner = HarborSurface()
    let bannerLabel = HarborUI.label("", size: 13, weight: .semibold)
    let bannerHint = HarborUI.label("", size: 12, secondary: true, wrap: true)
    let bannerAction = NSButton(title: L("Kiểm tra", "Check health"), target: nil, action: nil)
    let emptyAdd = NSButton(title: L("Thêm tài khoản đầu tiên", "Add your first account"), target: nil, action: nil)
    let reportButton = NSButton(title: L("Báo cáo & sao lưu", "Reports & backups"), target: nil, action: nil)
    let detailsButton = NSButton(title: L("Chi tiết", "Details"), target: nil, action: nil)
    let importButton = NSButton(title: L("Nhập lịch sử…", "Import history…"), target: nil, action: nil)
    let verifyButton = NSButton(title: L("Xác minh lịch sử", "Verify history"), target: nil, action: nil)
    #if BACKEND_TEST
    var activityStore: OperationActivityStore? = nil
    #else
    var activityStore: OperationActivityStore? = OperationActivityStore(directory: root)
    #endif
    var activityWarning: String?
    var previousLanguageMessage: String?
    var languageSwitchNotice: String?
    var addSheet: AddProfileSheetController?
    var phase = OperationPhase.idle
    var runtimeReady = false
    var recoveryNeeded = false
    var latestSummary: Summary?
    var signatureIssues: [String: [HealthIssue]] = [:]
    var request: ([String]) async throws -> Data = { try await backend($0) }
    var openRequest: (([Profile]) async -> [String])?
    var working: Bool { phase.isBusy }
    var waiting: Bool { phase.canCancel }
    var operation: Task<Void, Never>?
    var item: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        prepareWindow()
        showWindow(); setPhase(.starting)
        Task { await initializeRuntime() }
    }
    func prepareWindow() {
        let menu = NSMenu()
        let appMenu = NSMenuItem(); menu.addItem(appMenu)
        let appSub = NSMenu(); appMenu.submenu = appSub
        appSub.addItem(withTitle: L("Ẩn Claude Harbor", "Hide Claude Harbor"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appSub.addItem(.separator())
        appSub.addItem(withTitle: L("Thoát Claude Harbor", "Quit Claude Harbor"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); editItem.title = L("Sửa", "Edit"); menu.addItem(editItem)
        let edit = NSMenu(title: L("Sửa", "Edit")); editItem.submenu = edit
        for (title, selector, key) in [(L("Cắt", "Cut"), "cut:", "x"), (L("Sao chép", "Copy"), "copy:", "c"), (L("Dán", "Paste"), "paste:", "v"), (L("Chọn tất cả", "Select all"), "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        let actionsItem = NSMenuItem(); actionsItem.title = L("Tài khoản", "Accounts"); menu.addItem(actionsItem)
        let actions = NSMenu(title: L("Tài khoản", "Accounts")); actionsItem.submenu = actions
        for (title, action, key) in [(L("Thêm tài khoản…", "Add account…"), #selector(addProfile), "n"), (L("Mở tất cả", "Open all"), #selector(openEveryProfile), "o"), (L("Làm mới", "Refresh"), #selector(refreshNow), "r"), (L("Kiểm tra…", "Check health…"), #selector(showHealth), "i"), (L("Nhập lịch sử…", "Import history…"), #selector(importHistory), ""), (L("Xác minh lịch sử", "Verify history"), #selector(verifyHistory), ""), (L("Báo cáo & hoạt động…", "Reports & activity…"), #selector(showReport), "")] {
            let entry = actions.addItem(withTitle: title, action: action, keyEquivalent: key); entry.target = self
        }
        let language = NSMenuItem(title: "Language / Ngôn ngữ", action: nil, keyEquivalent: "")
        language.submenu = makeLanguageMenu(); menu.addItem(language)
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Claude Harbor"; window.center(); window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 820, height: 720)
        window.backgroundColor = .windowBackgroundColor
        let rootView = NSView(); window.contentView = rootView
        let title = HarborUI.label("Claude Harbor", size: 24, weight: .semibold)
        let subtitle = HarborUI.label(L("Nhiều tài khoản. Một nơi tiếp tục công việc.", "Multiple accounts. One place to keep working."), size: 13, secondary: true)
        let brandText = HarborUI.stack([title, subtitle], vertical: true, spacing: 5)
        let brand = HarborSurface(); brand.fill = NSColor.controlAccentColor.withAlphaComponent(0.10); brand.border = .clear
        let brandIcon = HarborUI.symbol("square.stack.3d.up.fill", size: 24, color: .controlAccentColor)
        HarborUI.pin(brandIcon, in: brand, inset: 12)
        brand.widthAnchor.constraint(equalToConstant: 48).isActive = true
        brand.heightAnchor.constraint(equalToConstant: 48).isActive = true
        add.target = self; add.action = #selector(addProfile); HarborUI.button(add, symbol: "plus")
        refresh.target = self; refresh.action = #selector(refreshNow); HarborUI.button(refresh, symbol: "arrow.clockwise")
        health.target = self; health.action = #selector(showHealth); HarborUI.button(health, symbol: "checkmark.shield")
        refresh.toolTip = L("Làm mới danh sách (⌘R)", "Refresh accounts (⌘R)"); health.toolTip = L("Kiểm tra bản Claude và phục hồi (⌘I)", "Check Claude copies and recovery (⌘I)"); add.toolTip = L("Thêm một bản Claude có đăng nhập riêng (⌘N)", "Add a Claude copy with its own login (⌘N)")
        let header = HarborUI.stack([brand, brandText, HarborUI.spacer(), refresh, health, add], spacing: 12)
        header.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        openAll.target = self; openAll.action = #selector(openEveryProfile); HarborUI.button(openAll, symbol: "arrow.up.forward.app")
        importButton.target = self; importButton.action = #selector(importHistory); HarborUI.button(importButton, symbol: "square.and.arrow.down")
        verifyButton.target = self; verifyButton.action = #selector(verifyHistory); HarborUI.button(verifyButton, symbol: "checkmark.seal")
        let historyHint = L("Chọn ít nhất một tài khoản đã khởi tạo, xử lý lỗi và đóng các bản Claude trước khi nhập hoặc xác minh.", "Select at least one initialized account, resolve issues and close Claude copies before importing or verifying.")
        importButton.toolTip = historyHint; verifyButton.toolTip = historyHint
        let overview = HarborUI.stack([overviewLabel, HarborUI.spacer(), importButton, verifyButton, openAll], spacing: 12)

        healthBanner.fill = NSColor.systemOrange.withAlphaComponent(0.08)
        healthBanner.border = NSColor.systemOrange.withAlphaComponent(0.20)
        let bannerText = HarborUI.stack([bannerLabel, bannerHint], vertical: true, spacing: 4)
        bannerAction.target = self; bannerAction.action = #selector(showHealth); HarborUI.button(bannerAction)
        let bannerContent = HarborUI.stack([HarborUI.symbol("exclamationmark.triangle.fill", size: 18, color: .systemOrange), bannerText, HarborUI.spacer(), bannerAction])
        HarborUI.pin(bannerContent, in: healthBanner, inset: 14)
        healthBanner.isHidden = true

        let listCard = HarborSurface()
        let listTitle = HarborUI.label(L("Tài khoản", "Accounts"), size: 16, weight: .semibold)
        let listHint = HarborUI.label(L("Chọn tài khoản được phép chia sẻ lịch sử Code.", "Choose which accounts may share Code history."), size: 12, secondary: true)
        let listText = HarborUI.stack([listTitle, listHint], vertical: true, spacing: 5)
        let listHeader = HarborUI.stack([listText, HarborUI.spacer(), selectionLabel])
        listCard.addSubview(listHeader)
        NSLayoutConstraint.activate([
            listHeader.leadingAnchor.constraint(equalTo: listCard.leadingAnchor, constant: 20),
            listHeader.trailingAnchor.constraint(equalTo: listCard.trailingAnchor, constant: -20),
            listHeader.topAnchor.constraint(equalTo: listCard.topAnchor, constant: 18),
        ])
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false; scroll.drawsBackground = false; scroll.borderType = .noBorder
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 8
        rows.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 8, right: 8)
        rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = rows
        listCard.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: listCard.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: listCard.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: listHeader.bottomAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: listCard.bottomAnchor, constant: -8),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 96),
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        listCard.setContentHuggingPriority(.init(1), for: .vertical)
        listCard.setContentCompressionResistancePriority(.init(500), for: .vertical)
        listCard.addSubview(emptyState); emptyState.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyState.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), emptyState.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: scroll.topAnchor), emptyState.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
        ])
        let emptyIcon = HarborUI.symbol("person.2.badge.plus", size: 32, color: .controlAccentColor)
        let emptyTitle = HarborUI.label(L("Thêm tài khoản đầu tiên của bạn", "Add your first account"), size: 18, weight: .semibold)
        let emptyHint = HarborUI.label(L("Mỗi tài khoản có một bản Claude riêng.\nLịch sử chỉ chia sẻ khi bạn chọn Đồng bộ.", "Each account has its own Claude app.\nHistory is shared only when you select Sync."), size: 13, secondary: true, wrap: true)
        emptyHint.alignment = .center
        emptyAdd.target = self; emptyAdd.action = #selector(addProfile); HarborUI.button(emptyAdd, symbol: "plus", prominent: true)
        let emptyContent = HarborUI.stack([emptyIcon, emptyTitle, emptyHint, emptyAdd], vertical: true, spacing: 12)
        emptyContent.alignment = .centerX; emptyState.addSubview(emptyContent)
        NSLayoutConstraint.activate([
            emptyContent.centerXAnchor.constraint(equalTo: emptyState.centerXAnchor), emptyContent.centerYAnchor.constraint(equalTo: emptyState.centerYAnchor),
            emptyContent.leadingAnchor.constraint(greaterThanOrEqualTo: emptyState.leadingAnchor, constant: 24),
            emptyContent.trailingAnchor.constraint(lessThanOrEqualTo: emptyState.trailingAnchor, constant: -24),
        ])

        let activity = HarborSurface(); activity.fill = .windowBackgroundColor
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.isSelectable = true
        status.maximumNumberOfLines = 4; status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.init(500), for: .horizontal)
        detailsButton.target = self; detailsButton.action = #selector(showOperationDetails)
        detailsButton.bezelStyle = .inline; detailsButton.isBordered = false
        detailsButton.font = .systemFont(ofSize: 12)
        detailsButton.contentTintColor = .controlAccentColor
        detailsButton.setAccessibilityLabel(L("Xem đầy đủ nội dung hoạt động", "Show full activity details"))
        let activityHeader = HarborUI.stack([operationHeading, progress, HarborUI.spacer(), detailsButton], spacing: 8)
        let activityText = HarborUI.stack([activityHeader, status], vertical: true, spacing: 6)
        activityText.setContentHuggingPriority(.init(1), for: .horizontal)
        status.widthAnchor.constraint(equalTo: activityText.widthAnchor).isActive = true
        reportButton.target = self; reportButton.action = #selector(showReport); HarborUI.button(reportButton, symbol: "folder")
        let activityContent = HarborUI.stack([HarborUI.symbol("clock.arrow.circlepath", size: 18), activityText, reportButton], spacing: 12)
        HarborUI.pin(activityContent, in: activity, inset: 14)
        activity.heightAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        let syncHeading = HarborUI.label(L("Đồng bộ lịch sử Code", "Sync Code history"), size: 15, weight: .semibold)
        footer.font = .systemFont(ofSize: 12); footer.textColor = .secondaryLabelColor
        footer.maximumNumberOfLines = 3
        let syncText = HarborUI.stack([syncHeading, footer], vertical: true, spacing: 6)
        syncText.setContentHuggingPriority(.init(1), for: .horizontal)
        footer.widthAnchor.constraint(equalTo: syncText.widthAnchor).isActive = true
        sync.target = self; sync.action = #selector(synchronize); HarborUI.button(sync, symbol: "arrow.triangle.2.circlepath", prominent: true)
        sync.keyEquivalent = "\r"; sync.keyEquivalentModifierMask = [.command]
        sync.widthAnchor.constraint(greaterThanOrEqualToConstant: 206).isActive = true
        let syncBar = HarborUI.stack([syncText, sync], spacing: 28)
        syncBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        let scope = HarborUI.label(L("Chỉ Code local trên máy này · Không gồm Chat web, Cowork hoặc cloud", "Local Code on this Mac only · Excludes web Chat, Cowork and cloud"), size: 11, secondary: true)
        let content = HarborUI.stack([header, overview, healthBanner, listCard, activity, syncBar, scope], vertical: true, spacing: 12)
        content.detachesHiddenViews = true
        HarborUI.pin(content, in: rootView, inset: 20)
        for view in content.arrangedSubviews { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Claude Harbor")
        let quick = NSMenu(); quick.autoenablesItems = false
        menuStatus.isEnabled = false; quick.addItem(menuStatus); quick.addItem(.separator())
        for (name, action) in [("Claude Harbor…", #selector(showWindow)), (L("Mở tất cả", "Open all"), #selector(openEveryProfile)), (L("Đồng bộ đã chọn", "Sync selected"), #selector(synchronize))] {
            let entry = quick.addItem(withTitle: name, action: action, keyEquivalent: ""); entry.target = self
        }
        let quickLanguage = NSMenuItem(title: "Language / Ngôn ngữ", action: nil, keyEquivalent: "")
        quickLanguage.submenu = makeLanguageMenu(); quick.addItem(quickLanguage)
        item.menu = quick
        updateControls()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if window?.attachedSheet != nil { return false }
        if menuItem.action == #selector(chooseLanguage(_:)) { return !working && addSheet == nil }
        if menuItem.action == #selector(importHistory) || menuItem.action == #selector(verifyHistory) { return historyActionAvailable }
        if menuItem.action == #selector(showReport) { return !working }
        if menuItem.action == #selector(refreshNow) { return !working }
        if menuItem.action == #selector(openEveryProfile) { return !working && runtimeReady && !profiles.isEmpty }
        return !working && runtimeReady
    }
    func makeLanguageMenu() -> NSMenu {
        let menu = NSMenu(title: "Language / Ngôn ngữ")
        for (title, preference) in [(L("Theo hệ thống", "System"), LanguagePreference.system), ("English", .english), ("Tiếng Việt", .vietnamese)] {
            let entry = menu.addItem(withTitle: title, action: #selector(chooseLanguage(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = preference.rawValue
            entry.state = L10n.preference == preference ? .on : .off
        }
        return menu
    }
    @objc func chooseLanguage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let preference = LanguagePreference(rawValue: value) else { return }
        _ = changeLanguage(to: preference)
    }
    @discardableResult func changeLanguage(to preference: LanguagePreference) -> Manager? {
        guard !working, window?.attachedSheet == nil, addSheet == nil else { return nil }
        guard L10n.preference != preference else { return self }
        L10n.setPreference(preference)
        // Recreate native controls to refresh titles, accessibility, tooltips and
        // menus together. This changes presentation only; no backend call is made.
        let replacement = Manager()
        replacement.request = request; replacement.openRequest = openRequest
        replacement.runtimeReady = runtimeReady
        replacement.activityStore = activityStore
        replacement.signatureIssues = signatureIssues
        let originalMessage = (status.stringValue == languageSwitchNotice ? previousLanguageMessage : nil) ?? status.stringValue
        replacement.previousLanguageMessage = originalMessage
        if activityWarning != nil {
            replacement.activityWarning = L("Không lưu được nhật ký hoạt động. Báo cáo runtime và bản sao lưu vẫn nằm trong thư mục Harbor.", "Could not save the activity log. Runtime reports and backups remain in the Harbor folder.")
        }
        replacement.prepareWindow()
        replacement.window.appearance = window.appearance
        replacement.window.setFrame(window.frame, display: false)
        if let latestSummary { replacement.render(latestSummary, showSummary: false) }
        // Keep the latest notice visible, including verification/recovery warnings.
        // Original diagnostics are not translated or replaced by a stale success.
        replacement.status.stringValue = L("Thông báo gần nhất (ngôn ngữ gốc):\n", "Latest message (original language):\n") + originalMessage
        replacement.languageSwitchNotice = replacement.status.stringValue
        let offset = scroll.contentView.bounds.origin
        replacement.scroll.contentView.scroll(to: NSPoint(x: 0, y: min(offset.y, max(0, replacement.rows.bounds.height - replacement.scroll.contentView.bounds.height))))
        replacement.scroll.reflectScrolledClipView(replacement.scroll.contentView)
        replacement.setPhase(.idle)
        if NSApp.delegate === self { NSApp.delegate = replacement }
        Manager.active = replacement
        window.close()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        replacement.showWindow()
        return replacement
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if waiting { operation?.cancel(); return .terminateNow }; return working ? .terminateCancel : .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func updateControls() {
        let available = !working && runtimeReady && window?.attachedSheet == nil
        let availability = SyncAvailability(profiles: profiles, runtimeReady: runtimeReady, recoveryNeeded: recoveryNeeded, phase: phase)
        importButton.isEnabled = historyActionAvailable; verifyButton.isEnabled = historyActionAvailable
        reportButton.isEnabled = !working && window?.attachedSheet == nil
        add.isEnabled = available; emptyAdd.isEnabled = available
        openAll.isEnabled = available && !profiles.isEmpty
        refresh.isEnabled = !working && window?.attachedSheet == nil; health.isEnabled = available; bannerAction.isEnabled = available
        sync.isEnabled = window?.attachedSheet == nil && (waiting || availability.isEnabled)
        sync.title = waiting ? L("Dừng chờ", "Stop waiting") : (availability.participantCount >= 2 ? L("Đồng bộ \(availability.participantCount) tài khoản", "Sync \(availability.participantCount) accounts") : L("Đồng bộ đã chọn", "Sync selected"))
        sync.image = NSImage(systemSymbolName: waiting ? "xmark.circle" : "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        sync.toolTip = availability.explanation + " (⌘↩)"
        footer.stringValue = availability.explanation
        selectionLabel.stringValue = profiles.contains(where: \.syncEnabled) ? L("Đã chọn \(profiles.filter(\.syncEnabled).count) / \(profiles.count)", "Selected \(profiles.filter(\.syncEnabled).count) / \(profiles.count)") : L("Chưa chọn tài khoản", "No accounts selected")
        overviewLabel.stringValue = L("\(profiles.count) tài khoản  ·  \(profiles.filter { $0.ready && !$0.health.contains(where: \.blocking) }.count) sẵn sàng  ·  \(profiles.filter(\.running).count) đang chạy", "\(profiles.count) accounts  ·  \(profiles.filter { $0.ready && !$0.health.contains(where: \.blocking) }.count) ready  ·  \(profiles.filter(\.running).count) running")
        let unhealthy = profiles.filter { $0.health.contains(where: \.blocking) }.count
        healthBanner.isHidden = !recoveryNeeded && unhealthy == 0
        bannerLabel.stringValue = recoveryNeeded ? L("Có giao dịch cần phục hồi", "An operation needs recovery") : L("\(unhealthy) tài khoản cần sửa bản Claude", "\(unhealthy) accounts need Claude repair")
        bannerHint.stringValue = recoveryNeeded ? L("Đóng các bản Claude rồi vào Kiểm tra → Phục hồi để tiếp tục.", "Close Claude apps, then choose Check health → Recover to continue.") : L("Sửa bản app hoặc bỏ chọn tài khoản bị lỗi trước khi đồng bộ.", "Repair the app or deselect the affected account before syncing.")
        operationHeading.stringValue = working ? phase.title : L("Hoạt động gần nhất", "Latest activity")
        status.toolTip = status.stringValue
        for case let row as NSStackView in rows.arrangedSubviews { for case let button as NSButton in row.arrangedSubviews { button.isEnabled = available } }
        if working { window?.styleMask.remove(.closable) } else { window?.styleMask.insert(.closable) }
        for entry in item?.menu?.items ?? [] {
            if entry.action == #selector(openEveryProfile) { entry.isEnabled = openAll.isEnabled }
            if entry.action == #selector(synchronize) { entry.isEnabled = sync.isEnabled; entry.title = sync.title }
        }
    }
    func setPhase(_ value: OperationPhase) {
        phase = value
        if value == .idle {
            menuStatus.title = runtimeReady ? (status.stringValue.components(separatedBy: "\n").first ?? value.title) : L("Runtime chưa sẵn sàng — mở Harbor để kiểm tra", "Runtime is not ready — open Harbor to check")
        } else { menuStatus.title = value.title }
        item?.button?.toolTip = menuStatus.title
        if value.isBusy { status.stringValue = value.title }
        if value.isBusy && value != .configuring { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        updateControls()
    }
    func initializeRuntime() async {
        do {
            if let bootstrap = Bundle.main.resourceURL?.appendingPathComponent("backend/bootstrap.py"), FileManager.default.fileExists(atPath: bootstrap.path) {
                _ = try await executePython([bootstrap.path])
            }
            let capabilities = try JSONDecoder().decode(RuntimeCapabilities.self, from: try await request(["capabilities"]))
            guard capabilities.isCompatible else { throw BackendFailure.incompatible }
            runtimeReady = true
            _ = await load()
        } catch {
            runtimeReady = false
            status.stringValue = L("Không khởi tạo được runtime: ", "Could not initialize runtime: ") + error.localizedDescription
        }
        setPhase(.idle)
    }
    @discardableResult func load(showSummary: Bool = true) async -> Bool {
        do {
            let summary = try JSONDecoder().decode(Summary.self, from: try await request(["status"]))
            render(summary, showSummary: showSummary)
            return true
        } catch {
            runtimeReady = false; updateControls()
            if showSummary { status.stringValue = L("Không làm mới được: ", "Could not refresh: ") + error.localizedDescription }
            return false
        }
    }
    func render(_ summary: Summary, showSummary: Bool = true) {
        latestSummary = summary
        profiles = summary.profiles.map { profile in
            var updated = profile
            updated.health += (signatureIssues[profile.id] ?? []).filter { issue in !profile.health.contains { $0.code == issue.code } }
            return updated
        }
        recoveryNeeded = summary.issues.contains(where: \.blocking)
        let scrollPosition = scroll.contentView.bounds.origin
        let focusedID = (window?.firstResponder as? NSView)?.identifier
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, profile) in profiles.enumerated() {
            let row = ProfileRowView(profile: profile, index: index, target: self)
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -16).isActive = true
        }
        emptyState.isHidden = !profiles.isEmpty
        scroll.isHidden = profiles.isEmpty
        window?.contentView?.layoutSubtreeIfNeeded()
        let maxScroll = max(0, rows.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(scrollPosition.y, maxScroll)))
        scroll.reflectScrolledClipView(scroll.contentView)
        if let focusedID {
            for case let row as NSStackView in rows.arrangedSubviews {
                if let replacement = row.arrangedSubviews.first(where: { $0.identifier == focusedID }) { window?.makeFirstResponder(replacement) }
            }
        }
        if showSummary {
            if let last = summary.lastSync { status.stringValue = L("Đã đồng bộ \(last.sessions) phiên giữa \(last.profiles) tài khoản. \(last.filesChanged) tệp cập nhật.\nBản sao lưu được giữ trong Báo cáo & sao lưu.", "Synced \(last.sessions) sessions across \(last.profiles) accounts. \(last.filesChanged) files updated.\nBackups are available in Reports & backups.")
            } else { status.stringValue = L("Chưa có báo cáo đồng bộ để hiển thị.", "No sync report to display yet.") }
            let pendingCount = profiles.filter { !$0.ready }.count
            if pendingCount > 0 { status.stringValue += L("\n\(pendingCount) tài khoản chờ đăng nhập hoặc mở tab Code.", "\n\(pendingCount) accounts need sign-in or Code setup.") }
            if recoveryNeeded { status.stringValue = L("Cần phục hồi trước khi đồng bộ. Đóng các bản Claude rồi chọn Kiểm tra → Phục hồi.", "Recovery is required before syncing. Close Claude apps, then choose Check health → Recover.") }
        }
        updateControls()
    }
    func applyHealthReport(_ report: HealthReport) {
        signatureIssues = Dictionary(grouping: report.issues.filter { $0.code == "invalid_signature" && $0.profile != nil }, by: { $0.profile! })
        if let summary = latestSummary {
            let checkedProfiles = summary.profiles.map { profile in
                var checked = profile
                checked.health = report.issues.filter { $0.profile == profile.id }
                return checked
            }
            render(Summary(profiles: checkedProfiles, pending: summary.pending, lastSync: summary.lastSync,
                           issues: report.issues.filter { $0.profile == nil }), showSummary: false)
        }
    }
    @objc func selectForSync(_ sender: NSButton) {
        guard !working, runtimeReady, profiles.indices.contains(sender.tag) else { return }
        let p = profiles[sender.tag]; let selected = sender.state == .on
        setPhase(.selecting)
        Task {
            do {
                _ = try await request(["select", p.id, selected ? "true" : "false"])
                recordActivity(.selection, .succeeded)
                let refreshed = await load(showSummary: false)
                status.stringValue = refreshed ? L("Đã lưu lựa chọn đồng bộ cho \(p.name).", "Saved sync selection for \(p.name).") : L("Đã lưu lựa chọn nhưng chưa làm mới được. Bấm Làm mới trước thao tác tiếp theo.", "Selection saved, but refresh failed. Click Refresh before continuing.")
            } catch {
                let message = error.localizedDescription
                _ = await load(showSummary: false)
                status.stringValue = message
            }
            setPhase(.idle)
        }
    }
    @objc func refreshNow() { guard !working else { return }; setPhase(.loading); Task { await initializeRuntime() } }
    @discardableResult func open(_ selected: [Profile]) async -> [String] {
        if let openRequest { return await openRequest(selected) }
        var failures: [String] = []
        for profile in selected {
            let config = NSWorkspace.OpenConfiguration(); config.activates = selected.count == 1
            let failure: String? = await withCheckedContinuation { continuation in
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: profile.bundle), configuration: config) { _, error in continuation.resume(returning: error?.localizedDescription) }
            }
            if let failure { failures.append(profile.name + ": " + failure) }
        }
        return failures
    }
    func openProfiles(_ selected: [Profile]) {
        guard !working, runtimeReady else { return }
        setPhase(.opening)
        Task {
            let failures = await open(selected)
            let refreshed = await load(showSummary: false)
            recordActivity(.open, failures.isEmpty && refreshed ? .succeeded : .needsAttention)
            status.stringValue = failures.isEmpty ? L("Đã gửi yêu cầu mở \(selected.count) app Claude.", "Requested opening \(selected.count) Claude apps.") : L("Không mở được: ", "Could not open: ") + failures.joined(separator: "; ")
            if !refreshed { status.stringValue += L("\nChưa làm mới được trạng thái; bấm Làm mới trước thao tác tiếp theo.", "\nCould not refresh status; click Refresh before continuing.") }
            setPhase(.idle)
        }
    }
    @objc func openOne(_ sender: NSButton) { guard profiles.indices.contains(sender.tag) else { return }; openProfiles([profiles[sender.tag]]) }
    @objc func openEveryProfile() { openProfiles(profiles) }
    @objc func addProfile() {
        guard !working, runtimeReady, window.attachedSheet == nil else { return }
        setPhase(.configuring)
        let controller = AddProfileSheetController()
        addSheet = controller
        controller.onClose = { [weak self] in
            guard let self else { return }
            if self.phase == .configuring { self.status.stringValue = L("Đã đóng cửa sổ thêm tài khoản.", "Closed the add-account window.") }
            self.addSheet = nil
            self.setPhase(.idle)
        }
        controller.onSubmit = { [weak self] title, type in
            guard let self else { throw BackendFailure.incompatible }
            self.setPhase(.creating)
            do {
                struct CreatedProfile: Decodable { let id: String }
                let created = try JSONDecoder().decode(CreatedProfile.self, from: try await self.request(["create", title, type]))
                let refreshed = await self.load(showSummary: false)
                var failures: [String] = []
                if refreshed, let profile = self.profiles.first(where: { $0.id == created.id }) {
                    self.setPhase(.opening); failures = await self.open([profile])
                }
                self.recordActivity(.create, refreshed && failures.isEmpty ? .succeeded : .needsAttention)
                self.status.stringValue = L("Đã tạo tài khoản. Đăng nhập trong bản Claude mới, mở Code rồi bấm Làm mới.", "Account created. Sign in to the new Claude app, open Code, then click Refresh.")
                if !refreshed { self.status.stringValue += L("\nChưa làm mới được danh sách; app mới chưa được mở.", "\nCould not refresh accounts; the new app has not been opened.") }
                if !failures.isEmpty { self.status.stringValue += L("\nKhông mở được: ", "\nCould not open: ") + failures.joined(separator: "; ") }
            } catch {
                self.recordActivity(.create, .failed)
                self.setPhase(.configuring)
                self.status.stringValue = L("Chưa tạo được tài khoản. Kiểm tra thông báo trong cửa sổ thêm tài khoản.", "Could not create the account. Check the message in the add-account window.")
                throw error
            }
        }
        controller.present(for: window)
    }
    @objc func showHealth() {
        guard !working, runtimeReady else { return }
        setPhase(.checking)
        Task {
            do {
                let report = try JSONDecoder().decode(HealthReport.self, from: try await request(["doctor"]))
                recordActivity(.health, report.ok ? .succeeded : .needsAttention)
                applyHealthReport(report)
                let alert = NSAlert(); alert.messageText = report.ok ? L("Kiểm tra hoàn tất", "Health check complete") : L("Cần xử lý trước khi đồng bộ", "Resolve these issues before syncing")
                alert.informativeText = report.issues.isEmpty ? L("Không phát hiện lỗi clone hoặc giao dịch dở dang.", "No clone problems or unfinished operations found.") : report.issues.map { issue in
                    let name = profiles.first { $0.id == issue.profile }?.name ?? "Claude Harbor"
                    return name + ": " + issue.displayText + " [\(issue.code)]"
                }.joined(separator: "\n")
                alert.addButton(withTitle: L("Đóng", "Close"))
                let canRecover = report.issues.contains { ["pending_recovery", "interrupted_clone_repair"].contains($0.code) }
                if canRecover { alert.addButton(withTitle: L("Phục hồi", "Recover")) }
                let response = await alert.beginSheetModal(for: window)
                if canRecover, response == .alertSecondButtonReturn {
                    setPhase(.recovering)
                    _ = try await request(["recover"])
                    recordActivity(.recovery, .succeeded)
                    let refreshed = await load(showSummary: false)
                    status.stringValue = refreshed ? L("Đã phục hồi giao dịch. Kiểm tra các profile trước khi đồng bộ lại.", "Operation recovered. Check profiles before syncing again.") : L("Đã phục hồi nhưng chưa làm mới được; bấm Làm mới.", "Recovered, but refresh failed; click Refresh.")
                } else { status.stringValue = report.ok ? L("Kiểm tra hoàn tất. Xem trạng thái từng profile trong danh sách.", "Health check complete. See each profile in the list.") : L("Cần xử lý các vấn đề đã báo trước khi đồng bộ.", "Resolve the reported issues before syncing.") }
            } catch { recordActivity(phase == .recovering ? .recovery : .health, .failed); status.stringValue = error.localizedDescription }
            setPhase(.idle)
        }
    }
    @objc func repairProfile(_ sender: NSButton) {
        guard !working, runtimeReady, profiles.indices.contains(sender.tag) else { return }
        let profile = profiles[sender.tag]
        setPhase(.repairing)
        Task {
            let alert = NSAlert(); alert.messageText = L("Sửa \(profile.name)?", "Repair \(profile.name)?")
            alert.informativeText = L("Đóng tất cả profile Claude trước khi sửa. Harbor tạo lại app từ /Applications/Claude.app và giữ thư mục đăng nhập, lịch sử riêng.", "Close all Claude profiles before repairing. Harbor rebuilds the app from /Applications/Claude.app and retains its separate login and history directories.")
            alert.addButton(withTitle: L("Sửa bản Claude", "Repair Claude copy")); alert.addButton(withTitle: L("Hủy", "Cancel"))
            if await alert.beginSheetModal(for: window) == .alertFirstButtonReturn {
                do {
                    _ = try await request(["repair", profile.id])
                    recordActivity(.repair, .succeeded)
                    signatureIssues[profile.id] = nil
                    let refreshed = await load(showSummary: false)
                    status.stringValue = refreshed ? L("Đã sửa \(profile.name). Có thể mở lại app.", "Repaired \(profile.name). You can reopen the app.") : L("Đã sửa app nhưng chưa làm mới được; bấm Làm mới.", "App repaired, but refresh failed; click Refresh.")
                } catch { recordActivity(.repair, .failed); status.stringValue = error.localizedDescription }
            } else { status.stringValue = L("Đã hủy sửa app.", "App repair cancelled."); recordActivity(.repair, .cancelled) }
            setPhase(.idle)
        }
    }
    @objc func showOperationDetails() {
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = L("Chi tiết hoạt động", "Activity details")
        alert.addButton(withTitle: L("Đóng", "Close"))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 220))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false; text.isSelectable = true
        text.font = .systemFont(ofSize: 13)
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.string = status.stringValue
        text.isHorizontallyResizable = false; text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        alert.accessoryView = scroll
        alert.beginSheetModal(for: window) { [weak self] _ in
            // AppKit clears attachedSheet after the dismissal callback returns.
            DispatchQueue.main.async { [weak self] in self?.updateControls() }
        }
        updateControls()
    }
    @objc func synchronize() {
        if waiting { operation?.cancel(); return }; guard !working, runtimeReady, sync.isEnabled else { return }
        setPhase(.checking); operation = Task { await performSync() }
    }
    func performSync() async {
        var previous: [Profile] = []; var closing = false; var syncApplied = false
        do {
            status.stringValue = L("Đang kiểm tra các phiên…", "Checking sessions…")
            var check = try JSONDecoder().decode(Check.self, from: try await request(["check"]))
            while true {
                if !check.errors.isEmpty { throw NSError(domain: "Sync", code: 1, userInfo: [NSLocalizedDescriptionKey: check.errors.joined(separator: "\n")]) }
                if check.busy.isEmpty { break }
                setPhase(.waiting)
                status.stringValue = L("Chờ trả lời xong: ", "Waiting for replies: ") + check.busyDescription(profiles: profiles)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                check = try JSONDecoder().decode(Check.self, from: try await request(["check"]))
            }
            try Task.checkCancellation()
            let closingProfiles = profiles.filter { check.running.contains($0.id) }
            let applications = closingProfiles.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID) }
            previous = closingProfiles.filter { p in applications.contains { $0.bundleIdentifier == p.bundleID } }
            setPhase(.closing); closing = true
            for app in applications { _ = app.terminate() }
            for _ in 0..<150 {
                if applications.allSatisfy(\.isTerminated) { break }; try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard applications.allSatisfy(\.isTerminated) else { throw NSError(domain: "Sync", code: 2, userInfo: [NSLocalizedDescriptionKey: L("Một app chưa đóng được; chưa ghi dữ liệu đồng bộ.", "An app did not close; sync data has not been written.")]) }
            setPhase(.syncing)
            let report = try JSONDecoder().decode(Report.self, from: try await request(["sync"]))
            syncApplied = true
            setPhase(.verifying); _ = try await request(["verify"])
            setPhase(.reopening); let reopenFailures = await open(previous)
            let refreshed = await load(showSummary: false)
            status.stringValue = L("Đã đồng bộ \(report.sessions) phiên vào \(report.profiles) app. \(report.filesChanged) tệp cập nhật.", "Synced \(report.sessions) sessions across \(report.profiles) apps. \(report.filesChanged) files updated.")
            if report.newBranches > 0 { status.stringValue += L(" Giữ thêm \(report.newBranches) nhánh.", " Preserved \(report.newBranches) additional branches.") }
            status.stringValue += L("\nCó bản sao lưu trong Báo cáo & sao lưu.", "\nA backup is available in Reports & backups.")
            if !reopenFailures.isEmpty { status.stringValue += L("\nKhông mở lại được: ", "\nCould not reopen: ") + reopenFailures.joined(separator: "; ") }
            if !refreshed { status.stringValue += L("\nChưa làm mới được trạng thái; bấm Làm mới trước thao tác tiếp theo.", "\nCould not refresh status; click Refresh before continuing.") }
            if let warnings = report.warnings, warnings > 0 { status.stringValue += L(" Có \(warnings) cảnh báo; phiên/profile có dữ liệu lỗi được bỏ qua. Xem file và dòng lỗi trong history-audit.json qua Báo cáo & sao lưu.", " \(warnings) warnings; sessions/profiles with invalid data were skipped. See file and line details in history-audit.json via Reports & backups.") }
            if let pending = report.pending, !pending.isEmpty { status.stringValue += L(" \(pending.count) profile chờ đăng nhập / khởi tạo Code.", " \(pending.count) profiles need sign-in / Code setup.") }
            recordActivity(.sync, (report.warnings ?? 0) > 0 || !reopenFailures.isEmpty || !refreshed ? .needsAttention : .succeeded, report: report)
        } catch is CancellationError { status.stringValue = L("Đã dừng chờ, chưa thay đổi lịch sử.", "Stopped waiting; history is unchanged."); recordActivity(.sync, .cancelled)
        } catch {
            let message = error.localizedDescription
            var failures: [String] = []
            if closing && !syncApplied { setPhase(.reopening); failures = await open(previous) }
            let refreshed = await load(showSummary: false)
            recordActivity(.sync, syncApplied ? .needsAttention : .failed)
            status.stringValue = (syncApplied ? L("Đã ghi đồng bộ nhưng chưa xác minh thành công: ", "Sync was written but verification did not succeed: ") : L("Chưa hoàn tất: ", "Not completed: ")) + message
            if syncApplied { status.stringValue += L("\nGiữ các app đã đóng; xem Báo cáo & sao lưu rồi xác minh thành công trước khi mở lại.", "\nApps remain closed; inspect Reports & backups and verify successfully before reopening.") }
            if !failures.isEmpty { status.stringValue += L("\nKhông mở lại được: ", "\nCould not reopen: ") + failures.joined(separator: "; ") }
            if !refreshed { status.stringValue += L("\nChưa làm mới được trạng thái; bấm Làm mới trước thao tác tiếp theo.", "\nCould not refresh status; click Refresh before continuing.") }
            else if recoveryNeeded { status.stringValue += L("\nCần phục hồi: đóng các profile rồi chọn Kiểm tra → Phục hồi.", "\nRecovery required: close profiles, then choose Check health → Recover.") }
        }
        operation = nil; setPhase(.idle)
    }
}
#if !BACKEND_TEST
@main struct EntryPoint {
    @MainActor static func main() {
        let app = NSApplication.shared
        Manager.active = Manager()
        app.setActivationPolicy(.regular); app.delegate = Manager.active
        app.run()
    }
}

#endif
