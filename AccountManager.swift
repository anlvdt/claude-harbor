import AppKit
import Foundation
import Darwin

struct Profile: Decodable, Sendable {
    let id: String; let name: String; let kind: String; let bundle: String; let bundleID: String
    let ready: Bool; let running: Bool; let syncEnabled: Bool; let sessions: Int; let archived: Int
    var health: [HealthIssue]
}
struct Summary: Decodable { let profiles: [Profile]; let pending: [String]; let lastSync: Report?; let issues: [HealthIssue] }
struct Check: Decodable { let busy: [String]; let errors: [String]; let running: [String]; let eligible: [String]; let pending: [String] }
struct Report: Decodable { let profiles: Int; let sessions: Int; let newBranches: Int; let filesChanged: Int; let backup: String; let warnings: Int?; let pending: [String]? }
struct HealthIssue: Decodable {
    let profile: String?; let code: String; let detail: String; let blocking: Bool
    var displayText: String {
        switch code {
        case "clone_layout_changed", "missing_binary", "clone_version_changed", "launcher_modified", "invalid_signature", "unreadable_clone":
            return "Đóng các bản Claude rồi chọn Sửa để khôi phục app."
        case "source_version_changed": return "Claude gốc đã cập nhật; có thể sửa để cập nhật bản riêng."
        case "source_unavailable": return "Chưa tìm thấy Claude gốc để tạo hoặc sửa bản riêng."
        case "pending_recovery", "interrupted_clone_repair": return "Có giao dịch chưa hoàn tất; đóng các profile rồi phục hồi."
        case "recovery_unreadable": return "Không đọc được nhật ký; giữ lại bản sao lưu và kiểm tra dữ liệu."
        default: return "Có vấn đề cần kiểm tra [\(code)]."
        }
    }
}
struct HealthReport: Decodable { let issues: [HealthIssue]; let ok: Bool }
struct BackendResult: Sendable { let status: Int32; let data: Data; let error: String }
struct BackendFailure: Decodable, LocalizedError {
    let code: String
    let message: String
    let remediation: String
    var errorDescription: String? { "\(message)\n\(remediation) [\(code)]" }
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
        case .idle: return "Sẵn sàng"
        case .starting: return "Đang khởi tạo…"
        case .loading: return "Đang làm mới…"
        case .selecting: return "Đang lưu lựa chọn…"
        case .opening: return "Đang mở Claude…"
        case .configuring: return "Thêm tài khoản"
        case .creating: return "Đang tạo bản Claude…"
        case .checking: return "Đang kiểm tra…"
        case .waiting: return "Đang chờ trả lời xong…"
        case .closing: return "Đang đóng các bản Claude…"
        case .syncing: return "Đang sao lưu và đồng bộ…"
        case .importing: return "Đang sao lưu và nhập lịch sử…"
        case .verifying: return "Đang xác minh lịch sử…"
        case .reopening: return "Đang mở lại các app…"
        case .repairing: return "Đang sửa bản Claude…"
        case .recovering: return "Đang phục hồi giao dịch…"
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
    var window: NSWindow!
    var profiles: [Profile] = []
    let status = NSTextField(wrappingLabelWithString: "Đang đọc các profile…")
    let footer = NSTextField(wrappingLabelWithString: "")
    let sync = NSButton(title: "Đồng bộ đã chọn", target: nil, action: nil)
    let add = NSButton(title: "Thêm tài khoản", target: nil, action: nil)
    let openAll = NSButton(title: "Mở tất cả", target: nil, action: nil)
    let refresh = NSButton(title: "Làm mới", target: nil, action: nil)
    let health = NSButton(title: "Kiểm tra", target: nil, action: nil)
    let progress = NSProgressIndicator()
    let menuStatus = NSMenuItem(title: "Đang khởi tạo…", action: nil, keyEquivalent: "")
    let rows = FlippedStackView()
    let scroll = NSScrollView()
    let emptyState = NSView()
    let overviewLabel = HarborUI.label("Tài khoản của bạn", size: 13, secondary: true)
    let selectionLabel = HarborUI.label("Chưa chọn tài khoản", size: 12, weight: .medium, secondary: true)
    let operationHeading = HarborUI.label("Hoạt động gần nhất", size: 12, weight: .semibold)
    let healthBanner = HarborSurface()
    let bannerLabel = HarborUI.label("", size: 13, weight: .semibold)
    let bannerHint = HarborUI.label("", size: 12, secondary: true, wrap: true)
    let bannerAction = NSButton(title: "Kiểm tra", target: nil, action: nil)
    let emptyAdd = NSButton(title: "Thêm tài khoản đầu tiên", target: nil, action: nil)
    let reportButton = NSButton(title: "Báo cáo & sao lưu", target: nil, action: nil)
    let detailsButton = NSButton(title: "Chi tiết", target: nil, action: nil)
    let importButton = NSButton(title: "Nhập lịch sử…", target: nil, action: nil)
    let verifyButton = NSButton(title: "Xác minh lịch sử", target: nil, action: nil)
    #if BACKEND_TEST
    var activityStore: OperationActivityStore? = nil
    #else
    var activityStore: OperationActivityStore? = OperationActivityStore(directory: root)
    #endif
    var activityWarning: String?
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
        appSub.addItem(withTitle: "Ẩn Claude Harbor", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appSub.addItem(.separator())
        appSub.addItem(withTitle: "Thoát Claude Harbor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); editItem.title = "Sửa"; menu.addItem(editItem)
        let edit = NSMenu(title: "Sửa"); editItem.submenu = edit
        for (title, selector, key) in [("Cắt", "cut:", "x"), ("Sao chép", "copy:", "c"), ("Dán", "paste:", "v"), ("Chọn tất cả", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        let actionsItem = NSMenuItem(); actionsItem.title = "Tài khoản"; menu.addItem(actionsItem)
        let actions = NSMenu(title: "Tài khoản"); actionsItem.submenu = actions
        for (title, action, key) in [("Thêm tài khoản…", #selector(addProfile), "n"), ("Mở tất cả", #selector(openEveryProfile), "o"), ("Làm mới", #selector(refreshNow), "r"), ("Kiểm tra…", #selector(showHealth), "i"), ("Nhập lịch sử…", #selector(importHistory), ""), ("Xác minh lịch sử", #selector(verifyHistory), ""), ("Báo cáo & hoạt động…", #selector(showReport), "")] {
            let entry = actions.addItem(withTitle: title, action: action, keyEquivalent: key); entry.target = self
        }
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Claude Harbor"; window.center(); window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 820, height: 720)
        window.backgroundColor = .windowBackgroundColor
        let rootView = NSView(); window.contentView = rootView
        let title = HarborUI.label("Claude Harbor", size: 24, weight: .semibold)
        let subtitle = HarborUI.label("Nhiều tài khoản. Một nơi tiếp tục công việc.", size: 13, secondary: true)
        let brandText = HarborUI.stack([title, subtitle], vertical: true, spacing: 5)
        let brand = HarborSurface(); brand.fill = NSColor.controlAccentColor.withAlphaComponent(0.10); brand.border = .clear
        let brandIcon = HarborUI.symbol("square.stack.3d.up.fill", size: 24, color: .controlAccentColor)
        HarborUI.pin(brandIcon, in: brand, inset: 12)
        brand.widthAnchor.constraint(equalToConstant: 48).isActive = true
        brand.heightAnchor.constraint(equalToConstant: 48).isActive = true
        add.target = self; add.action = #selector(addProfile); HarborUI.button(add, symbol: "plus")
        refresh.target = self; refresh.action = #selector(refreshNow); HarborUI.button(refresh, symbol: "arrow.clockwise")
        health.target = self; health.action = #selector(showHealth); HarborUI.button(health, symbol: "checkmark.shield")
        refresh.toolTip = "Làm mới danh sách (⌘R)"; health.toolTip = "Kiểm tra bản Claude và phục hồi (⌘I)"; add.toolTip = "Thêm một bản Claude có đăng nhập riêng (⌘N)"
        let header = HarborUI.stack([brand, brandText, HarborUI.spacer(), refresh, health, add], spacing: 12)
        header.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        openAll.target = self; openAll.action = #selector(openEveryProfile); HarborUI.button(openAll, symbol: "arrow.up.forward.app")
        importButton.target = self; importButton.action = #selector(importHistory); HarborUI.button(importButton, symbol: "square.and.arrow.down")
        verifyButton.target = self; verifyButton.action = #selector(verifyHistory); HarborUI.button(verifyButton, symbol: "checkmark.seal")
        let historyHint = "Chọn ít nhất một tài khoản đã khởi tạo, xử lý lỗi và đóng các bản Claude trước khi nhập hoặc xác minh."
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
        let listTitle = HarborUI.label("Tài khoản", size: 16, weight: .semibold)
        let listHint = HarborUI.label("Chọn tài khoản được phép chia sẻ lịch sử Code.", size: 12, secondary: true)
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
        let emptyTitle = HarborUI.label("Thêm tài khoản đầu tiên của bạn", size: 18, weight: .semibold)
        let emptyHint = HarborUI.label("Mỗi tài khoản có một bản Claude riêng.\nLịch sử chỉ chia sẻ khi bạn chọn Đồng bộ.", size: 13, secondary: true, wrap: true)
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
        detailsButton.setAccessibilityLabel("Xem đầy đủ nội dung hoạt động")
        let activityHeader = HarborUI.stack([operationHeading, progress, HarborUI.spacer(), detailsButton], spacing: 8)
        let activityText = HarborUI.stack([activityHeader, status], vertical: true, spacing: 6)
        activityText.setContentHuggingPriority(.init(1), for: .horizontal)
        status.widthAnchor.constraint(equalTo: activityText.widthAnchor).isActive = true
        reportButton.target = self; reportButton.action = #selector(showReport); HarborUI.button(reportButton, symbol: "folder")
        let activityContent = HarborUI.stack([HarborUI.symbol("clock.arrow.circlepath", size: 18), activityText, reportButton], spacing: 12)
        HarborUI.pin(activityContent, in: activity, inset: 14)
        activity.heightAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        let syncHeading = HarborUI.label("Đồng bộ lịch sử Code", size: 15, weight: .semibold)
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
        let scope = HarborUI.label("Chỉ Code local trên máy này · Không gồm Chat web, Cowork hoặc cloud", size: 11, secondary: true)
        let content = HarborUI.stack([header, overview, healthBanner, listCard, activity, syncBar, scope], vertical: true, spacing: 12)
        content.detachesHiddenViews = true
        HarborUI.pin(content, in: rootView, inset: 20)
        for view in content.arrangedSubviews { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Claude Harbor")
        let quick = NSMenu(); quick.autoenablesItems = false
        menuStatus.isEnabled = false; quick.addItem(menuStatus); quick.addItem(.separator())
        for (name, action) in [("Claude Harbor…", #selector(showWindow)), ("Mở tất cả", #selector(openEveryProfile)), ("Đồng bộ đã chọn", #selector(synchronize))] {
            let entry = quick.addItem(withTitle: name, action: action, keyEquivalent: ""); entry.target = self
        }
        item.menu = quick
        updateControls()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if window?.attachedSheet != nil { return false }
        if menuItem.action == #selector(importHistory) || menuItem.action == #selector(verifyHistory) { return historyActionAvailable }
        if menuItem.action == #selector(showReport) { return !working }
        if menuItem.action == #selector(refreshNow) { return !working }
        if menuItem.action == #selector(openEveryProfile) { return !working && runtimeReady && !profiles.isEmpty }
        return !working && runtimeReady
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
        sync.title = waiting ? "Dừng chờ" : (availability.participantCount >= 2 ? "Đồng bộ \(availability.participantCount) tài khoản" : "Đồng bộ đã chọn")
        sync.image = NSImage(systemSymbolName: waiting ? "xmark.circle" : "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        sync.toolTip = availability.explanation + " (⌘↩)"
        footer.stringValue = availability.explanation
        selectionLabel.stringValue = profiles.contains(where: \.syncEnabled) ? "Đã chọn \(profiles.filter(\.syncEnabled).count) / \(profiles.count)" : "Chưa chọn tài khoản"
        overviewLabel.stringValue = "\(profiles.count) tài khoản  ·  \(profiles.filter { $0.ready && !$0.health.contains(where: \.blocking) }.count) sẵn sàng  ·  \(profiles.filter(\.running).count) đang chạy"
        let unhealthy = profiles.filter { $0.health.contains(where: \.blocking) }.count
        healthBanner.isHidden = !recoveryNeeded && unhealthy == 0
        bannerLabel.stringValue = recoveryNeeded ? "Có giao dịch cần phục hồi" : "\(unhealthy) tài khoản cần sửa bản Claude"
        bannerHint.stringValue = recoveryNeeded ? "Đóng các bản Claude rồi vào Kiểm tra → Phục hồi để tiếp tục." : "Sửa bản app hoặc bỏ chọn tài khoản bị lỗi trước khi đồng bộ."
        operationHeading.stringValue = working ? phase.title : "Hoạt động gần nhất"
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
            menuStatus.title = runtimeReady ? (status.stringValue.components(separatedBy: "\n").first ?? value.title) : "Runtime chưa sẵn sàng — mở Harbor để kiểm tra"
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
            status.stringValue = "Không khởi tạo được runtime: " + error.localizedDescription
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
            if showSummary { status.stringValue = "Không làm mới được: " + error.localizedDescription }
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
            if let last = summary.lastSync { status.stringValue = "Đã đồng bộ \(last.sessions) phiên giữa \(last.profiles) tài khoản. \(last.filesChanged) tệp cập nhật.\nBản sao lưu được giữ trong Báo cáo & sao lưu."
            } else { status.stringValue = "Chưa có báo cáo đồng bộ để hiển thị." }
            let pendingCount = profiles.filter { !$0.ready }.count
            if pendingCount > 0 { status.stringValue += "\n\(pendingCount) tài khoản chờ đăng nhập hoặc mở tab Code." }
            if recoveryNeeded { status.stringValue = "Cần phục hồi trước khi đồng bộ. Đóng các bản Claude rồi chọn Kiểm tra → Phục hồi." }
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
                status.stringValue = refreshed ? "Đã lưu lựa chọn đồng bộ cho \(p.name)." : "Đã lưu lựa chọn nhưng chưa làm mới được. Bấm Làm mới trước thao tác tiếp theo."
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
            status.stringValue = failures.isEmpty ? "Đã gửi yêu cầu mở \(selected.count) app Claude." : "Không mở được: " + failures.joined(separator: "; ")
            if !refreshed { status.stringValue += "\nChưa làm mới được trạng thái; bấm Làm mới trước thao tác tiếp theo." }
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
            if self.phase == .configuring { self.status.stringValue = "Đã đóng cửa sổ thêm tài khoản." }
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
                self.status.stringValue = "Đã tạo tài khoản. Đăng nhập trong bản Claude mới, mở Code rồi bấm Làm mới."
                if !refreshed { self.status.stringValue += "\nChưa làm mới được danh sách; app mới chưa được mở." }
                if !failures.isEmpty { self.status.stringValue += "\nKhông mở được: " + failures.joined(separator: "; ") }
            } catch {
                self.recordActivity(.create, .failed)
                self.setPhase(.configuring)
                self.status.stringValue = "Chưa tạo được tài khoản. Kiểm tra thông báo trong cửa sổ thêm tài khoản."
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
                let alert = NSAlert(); alert.messageText = report.ok ? "Kiểm tra hoàn tất" : "Cần xử lý trước khi đồng bộ"
                alert.informativeText = report.issues.isEmpty ? "Không phát hiện lỗi clone hoặc giao dịch dở dang." : report.issues.map { issue in
                    let name = profiles.first { $0.id == issue.profile }?.name ?? "Claude Harbor"
                    return name + ": " + issue.displayText + " [\(issue.code)]"
                }.joined(separator: "\n")
                alert.addButton(withTitle: "Đóng")
                let canRecover = report.issues.contains { ["pending_recovery", "interrupted_clone_repair"].contains($0.code) }
                if canRecover { alert.addButton(withTitle: "Phục hồi") }
                let response = await alert.beginSheetModal(for: window)
                if canRecover, response == .alertSecondButtonReturn {
                    setPhase(.recovering)
                    _ = try await request(["recover"])
                    recordActivity(.recovery, .succeeded)
                    let refreshed = await load(showSummary: false)
                    status.stringValue = refreshed ? "Đã phục hồi giao dịch. Kiểm tra các profile trước khi đồng bộ lại." : "Đã phục hồi nhưng chưa làm mới được; bấm Làm mới."
                } else { status.stringValue = report.ok ? "Kiểm tra hoàn tất. Xem trạng thái từng profile trong danh sách." : "Cần xử lý các vấn đề đã báo trước khi đồng bộ." }
            } catch { recordActivity(phase == .recovering ? .recovery : .health, .failed); status.stringValue = error.localizedDescription }
            setPhase(.idle)
        }
    }
    @objc func repairProfile(_ sender: NSButton) {
        guard !working, runtimeReady, profiles.indices.contains(sender.tag) else { return }
        let profile = profiles[sender.tag]
        setPhase(.repairing)
        Task {
            let alert = NSAlert(); alert.messageText = "Sửa \(profile.name)?"
            alert.informativeText = "Đóng tất cả profile Claude trước khi sửa. Harbor tạo lại app từ /Applications/Claude.app và giữ thư mục đăng nhập, lịch sử riêng."
            alert.addButton(withTitle: "Sửa bản Claude"); alert.addButton(withTitle: "Hủy")
            if await alert.beginSheetModal(for: window) == .alertFirstButtonReturn {
                do {
                    _ = try await request(["repair", profile.id])
                    recordActivity(.repair, .succeeded)
                    signatureIssues[profile.id] = nil
                    let refreshed = await load(showSummary: false)
                    status.stringValue = refreshed ? "Đã sửa \(profile.name). Có thể mở lại app." : "Đã sửa app nhưng chưa làm mới được; bấm Làm mới."
                } catch { recordActivity(.repair, .failed); status.stringValue = error.localizedDescription }
            } else { status.stringValue = "Đã hủy sửa app."; recordActivity(.repair, .cancelled) }
            setPhase(.idle)
        }
    }
    @objc func showOperationDetails() {
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "Chi tiết hoạt động"
        alert.addButton(withTitle: "Đóng")
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
            status.stringValue = "Đang kiểm tra các phiên…"
            var check = try JSONDecoder().decode(Check.self, from: try await request(["check"]))
            while true {
                if !check.errors.isEmpty { throw NSError(domain: "Sync", code: 1, userInfo: [NSLocalizedDescriptionKey: check.errors.joined(separator: "\n")]) }
                if check.busy.isEmpty { break }
                setPhase(.waiting)
                status.stringValue = "Chờ trả lời xong: " + check.busy.joined(separator: "; ")
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
            guard applications.allSatisfy(\.isTerminated) else { throw NSError(domain: "Sync", code: 2, userInfo: [NSLocalizedDescriptionKey: "Một app chưa đóng được; chưa ghi dữ liệu đồng bộ."]) }
            setPhase(.syncing)
            let report = try JSONDecoder().decode(Report.self, from: try await request(["sync"]))
            syncApplied = true
            setPhase(.verifying); _ = try await request(["verify"])
            setPhase(.reopening); let reopenFailures = await open(previous)
            let refreshed = await load(showSummary: false)
            status.stringValue = "Đã đồng bộ \(report.sessions) phiên vào \(report.profiles) app. \(report.filesChanged) tệp cập nhật.\(report.newBranches > 0 ? " Giữ thêm \(report.newBranches) nhánh." : "")\nCó bản sao lưu trong Báo cáo & sao lưu."
            if !reopenFailures.isEmpty { status.stringValue += "\nKhông mở lại được: " + reopenFailures.joined(separator: "; ") }
            if !refreshed { status.stringValue += "\nChưa làm mới được trạng thái; bấm Làm mới trước thao tác tiếp theo." }
            if let warnings = report.warnings, warnings > 0 { status.stringValue += " Có \(warnings) cảnh báo; phiên/profile có dữ liệu lỗi được bỏ qua. Xem file và dòng lỗi trong history-audit.json qua Báo cáo & sao lưu." }
            if let pending = report.pending, !pending.isEmpty { status.stringValue += " \(pending.count) profile chờ đăng nhập / khởi tạo Code." }
            recordActivity(.sync, (report.warnings ?? 0) > 0 || !reopenFailures.isEmpty || !refreshed ? .needsAttention : .succeeded, report: report)
        } catch is CancellationError { status.stringValue = "Đã dừng chờ, chưa thay đổi lịch sử."; recordActivity(.sync, .cancelled)
        } catch {
            let message = error.localizedDescription
            var failures: [String] = []
            if closing && !syncApplied { setPhase(.reopening); failures = await open(previous) }
            let refreshed = await load(showSummary: false)
            recordActivity(.sync, syncApplied ? .needsAttention : .failed)
            status.stringValue = (syncApplied ? "Đã ghi đồng bộ nhưng chưa xác minh thành công: " : "Chưa hoàn tất: ") + message
            if syncApplied { status.stringValue += "\nGiữ các app đã đóng; xem Báo cáo & sao lưu rồi xác minh thành công trước khi mở lại." }
            if !failures.isEmpty { status.stringValue += "\nKhông mở lại được: " + failures.joined(separator: "; ") }
            if !refreshed { status.stringValue += "\nChưa làm mới được trạng thái; bấm Làm mới trước thao tác tiếp theo." }
            else if recoveryNeeded { status.stringValue += "\nCần phục hồi: đóng các profile rồi chọn Kiểm tra → Phục hồi." }
        }
        operation = nil; setPhase(.idle)
    }
}
#if !BACKEND_TEST
@main struct EntryPoint {
    @MainActor static func main() {
        let app = NSApplication.shared; let delegate = Manager()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

#endif
