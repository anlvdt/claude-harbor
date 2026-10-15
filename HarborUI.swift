import AppKit

struct SyncAvailability {
    let isEnabled: Bool
    let explanation: String
    let participantCount: Int

    init(profiles: [Profile], runtimeReady: Bool, recoveryNeeded: Bool, phase: OperationPhase) {
        let ready = profiles.filter(\.ready)
        let participants = ready.filter(\.syncEnabled)
        participantCount = participants.count
        isEnabled = runtimeReady && !recoveryNeeded && !phase.isBusy && participants.count >= 2 && !participants.contains { $0.health.contains(where: \.blocking) }
        if phase.canCancel {
            explanation = "Chờ Claude trả lời xong. Bạn có thể dừng chờ; lịch sử chưa thay đổi."
        } else if phase == .configuring {
            explanation = "Hoàn tất hoặc đóng cửa sổ thêm tài khoản để tiếp tục."
        } else if phase.isBusy {
            explanation = "Thao tác đang chạy. Giữ Harbor mở cho đến khi hoàn tất."
        } else if !runtimeReady {
            explanation = "Bấm Làm mới để kết nối lại trước khi thao tác."
        } else if recoveryNeeded {
            explanation = "Cần phục hồi giao dịch trước khi đồng bộ. Đóng các bản Claude rồi chọn Kiểm tra."
        } else if profiles.isEmpty {
            explanation = "Thêm tài khoản đầu tiên để bắt đầu."
        } else if participants.contains(where: { $0.health.contains(where: \.blocking) }) {
            explanation = "Sửa bản Claude bị lỗi hoặc bỏ chọn tài khoản đó trước khi đồng bộ."
        } else if profiles.count < 2 {
            explanation = "Thêm tài khoản thứ hai để chia sẻ lịch sử Code."
        } else if ready.count < 2 {
            explanation = "Đăng nhập và mở tab Code ở ít nhất hai tài khoản để tiếp tục."
        } else if participants.count < 2 {
            explanation = "Chọn Đồng bộ ở ít nhất hai tài khoản sẵn sàng."
        } else {
            explanation = "Các bản Claude đang chạy sẽ đóng trong lúc ghi, rồi được mở lại. Đăng nhập luôn giữ riêng."
                + (profiles.contains(where: { $0.syncEnabled && !$0.ready }) ? " Tài khoản chưa thiết lập sẽ được bỏ qua." : "")
        }
    }
}

@MainActor enum HarborUI {
    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, secondary: Bool = false, wrap: Bool = false) -> NSTextField {
        let label = wrap ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    static func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.distribution = .fill
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }

    static func symbol(_ name: String, size: CGFloat = 16, color: NSColor = .secondaryLabelColor) -> NSImageView {
        let image = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: size, weight: .medium)
        image.contentTintColor = color
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: size).isActive = true
        image.heightAnchor.constraint(equalToConstant: size).isActive = true
        image.setAccessibilityElement(false)
        return image
    }

    static func button(_ button: NSButton, symbol: String? = nil, prominent: Bool = false) {
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13, weight: prominent ? .semibold : .medium)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
        }
        if prominent { button.bezelColor = .controlAccentColor }
    }

    static func pin(_ view: NSView, in parent: NSView, inset: CGFloat = 0) {
        parent.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
        ])
    }
}

@MainActor class HarborSurface: NSView {
    var fill: NSColor = .controlBackgroundColor
    var border: NSColor = .separatorColor
    var radius: CGFloat = 12
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        fill.setFill(); shape.fill()
        border.setStroke(); shape.lineWidth = 1; shape.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

@MainActor final class HarborBadge: HarborSurface {
    init(text: String, symbol: String, color: NSColor) {
        super.init(frame: .zero)
        fill = color.withAlphaComponent(0.10); border = .clear; radius = 6
        let icon = HarborUI.symbol(symbol, size: 10, color: color)
        let label = HarborUI.label(text, size: 11, weight: .medium)
        let content = HarborUI.stack([icon, label], spacing: 5)
        HarborUI.pin(content, in: self, inset: 6)
        widthAnchor.constraint(equalToConstant: ceil(label.intrinsicContentSize.width) + 27).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor final class ProfileRowView: NSStackView {
    let profileID: String
    let selected: Bool

    init(profile: Profile, index: Int, target: Manager) {
        profileID = profile.id; selected = profile.syncEnabled
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; distribution = .fill; spacing = 12
        edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        translatesAutoresizingMaskIntoConstraints = false
        let avatar = HarborSurface()
        avatar.fill = (profile.kind == "magpie" ? NSColor.systemPurple : .controlAccentColor).withAlphaComponent(0.10)
        avatar.border = .clear; avatar.radius = 10
        let avatarIcon = HarborUI.symbol(profile.kind == "magpie" ? "network" : "person.fill", size: 18, color: profile.kind == "magpie" ? .systemPurple : .controlAccentColor)
        HarborUI.pin(avatarIcon, in: avatar, inset: 9)
        avatar.widthAnchor.constraint(equalToConstant: 36).isActive = true
        avatar.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let title = HarborUI.label(profile.name, size: 14, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail; title.toolTip = profile.name
        title.setContentCompressionResistancePriority(.init(500), for: .horizontal)
        let provider = profile.kind == "magpie" ? "Magpie · Gateway local" : "Claude Desktop"
        let meta = HarborUI.label(profile.ready ? "\(provider) · \(profile.sessions) phiên Code" : provider, size: 12, secondary: true)
        meta.lineBreakMode = .byTruncatingTail
        let text = HarborUI.stack([title, meta], vertical: true, spacing: 5)
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        let fault = profile.health.first(where: \.blocking) ?? profile.health.first
        if let fault {
            let hint = HarborUI.label(fault.displayText, size: 12, secondary: true, wrap: true)
            hint.maximumNumberOfLines = 2; hint.toolTip = fault.displayText
            text.addArrangedSubview(hint)
            hint.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        } else if !profile.ready {
            let hint = HarborUI.label("Đăng nhập, mở Code và tạo một phiên local.", size: 12, secondary: true, wrap: true)
            text.addArrangedSubview(hint)
            hint.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        }
        let blocked = profile.health.contains(where: \.blocking)
        let badgeTitle = blocked ? "Cần sửa" : (!profile.ready ? "Cần thiết lập" : (profile.running ? "Đang chạy" : "Sẵn sàng"))
        let badge = HarborBadge(text: badgeTitle, symbol: blocked || !profile.ready ? "exclamationmark.circle.fill" : (profile.running ? "circle.fill" : "checkmark.circle.fill"), color: blocked || !profile.ready ? .systemOrange : .systemGreen)
        let chosen = NSButton(checkboxWithTitle: "Đồng bộ", target: target, action: #selector(Manager.selectForSync(_:)))
        chosen.tag = index; chosen.state = selected ? .on : .off
        chosen.identifier = .init("sync.\(profile.id)")
        chosen.toolTip = "Cho phép chia sẻ lịch sử Code với các tài khoản được chọn khác."
        chosen.setAccessibilityLabel("Đồng bộ lịch sử Code của \(profile.name)")
        chosen.setContentCompressionResistancePriority(.required, for: .horizontal)
        chosen.widthAnchor.constraint(equalToConstant: 86).isActive = true
        let open = NSButton(title: "Mở", target: target, action: #selector(Manager.openOne(_:)))
        open.tag = index; open.identifier = .init("open.\(profile.id)")
        open.setAccessibilityLabel("Mở \(profile.name)")
        HarborUI.button(open)
        for view in [avatar, text, badge, chosen] { addArrangedSubview(view) }
        if profile.health.contains(where: { $0.blocking || $0.code == "source_version_changed" }) {
            let repair = NSButton(title: "Sửa", target: target, action: #selector(Manager.repairProfile(_:)))
            repair.tag = index; repair.identifier = .init("repair.\(profile.id)")
            repair.setAccessibilityLabel("Sửa bản app của \(profile.name)")
            HarborUI.button(repair)
            addArrangedSubview(repair)
        }
        addArrangedSubview(open)
        text.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        title.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        meta.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        heightAnchor.constraint(greaterThanOrEqualToConstant: 88).isActive = true
        setAccessibilityLabel(profile.name)
    }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        (selected ? NSColor.controlAccentColor.withAlphaComponent(0.05) : NSColor.controlBackgroundColor).setFill(); shape.fill()
        (selected ? NSColor.controlAccentColor.withAlphaComponent(0.25) : NSColor.separatorColor.withAlphaComponent(0.5)).setStroke()
        shape.lineWidth = 1; shape.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}
