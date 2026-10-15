import AppKit

enum ProfileNameValidation {
    static func message(for value: String) -> String? {
        if value.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\:\0\r\n")) != nil {
            return L("Tên không được chứa /, \\, dấu hai chấm hoặc ký tự xuống dòng.", "Names cannot contain /, \\, colons, or line breaks.")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L("Nhập tên cho bản Claude mới.", "Enter a name for the new Claude app.") }
        guard trimmed.unicodeScalars.count <= 60 else { return L("Tên cần có từ 1 đến 60 ký tự.", "Names must contain 1 to 60 characters.") }
        return nil
    }
}

@MainActor final class AddProfileSheetController: NSObject, NSTextFieldDelegate {
    let name = NSTextField()
    let kind = NSPopUpButton()
    let submitButton = NSButton(title: L("Tạo và mở", "Create and open"), target: nil, action: nil)
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    var onSubmit: ((String, String) async throws -> Void)?
    var onClose: (() -> Void)?

    private let cancelButton = NSButton(title: L("Hủy", "Cancel"), target: nil, action: nil)
    private let providerDescription = NSTextField(wrappingLabelWithString: "")
    private var sheet: NSWindow?
    private var submitting = false
    private var closed = false

    override init() {
        super.init()
        name.placeholderString = L("Ví dụ: Công việc, Cá nhân…", "For example: Work, Personal…")
        name.delegate = self
        name.setAccessibilityLabel(L("Tên bản Claude", "Claude app name"))
        name.setAccessibilityHelp(L("Từ 1 đến 60 ký tự. Mỗi bản có đăng nhập riêng.", "1 to 60 characters. Each app has its own sign-in."))
        kind.addItems(withTitles: ["Claude Pro / Max", L("Magpie — thử nghiệm", "Magpie — experimental")])
        kind.target = self
        kind.action = #selector(providerChanged)
        kind.setAccessibilityLabel(L("Loại tài khoản", "Account type"))
        submitButton.bezelStyle = .rounded
        submitButton.target = self
        submitButton.action = #selector(submit)
        submitButton.keyEquivalent = "\r"
        submitButton.setAccessibilityLabel(L("Tạo và mở bản Claude", "Create and open the Claude app"))
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityLabel(L("Hủy thêm bản Claude", "Cancel adding a Claude app"))
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.setAccessibilityLabel(L("Lỗi tạo bản Claude", "Claude app creation error"))
        providerDescription.font = .systemFont(ofSize: 12)
        providerDescription.textColor = .secondaryLabelColor
        providerChanged()
        validate(showError: false)
    }

    func present(for parent: NSWindow) {
        guard !submitting, sheet?.sheetParent == nil, parent.attachedSheet == nil else { return }
        closed = false
        if sheet == nil { sheet = makeSheet() }
        guard let sheet else { return }
        validate(showError: false)
        parent.beginSheet(sheet)
        sheet.makeFirstResponder(name)
    }

    func validate(showError: Bool = true) {
        let message = ProfileNameValidation.message(for: name.stringValue)
        submitButton.isEnabled = message == nil && !submitting && !closed
        if showError { showErrorMessage(message ?? "") }
    }

    func create() async {
        guard !submitting, !closed else { return }
        validate()
        guard ProfileNameValidation.message(for: name.stringValue) == nil else {
            sheet?.makeFirstResponder(name)
            return
        }
        guard let onSubmit else {
            showErrorMessage(L("Chưa sẵn sàng tạo bản mới. Vui lòng thử lại.", "Not ready to create a new app. Please try again."))
            return
        }
        let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = kind.indexOfSelectedItem == 1 ? "magpie" : "claude"
        setSubmitting(true)
        do {
            try await onSubmit(title, provider)
            setSubmitting(false)
            close()
        } catch {
            setSubmitting(false)
            showErrorMessage(error.localizedDescription)
        }
    }

    func controlTextDidChange(_ obj: Notification) { validate() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancel()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            submit()
            return true
        }
        return false
    }

    @objc private func submit() { Task { await create() } }

    @objc private func cancel() {
        guard !submitting else { return }
        close()
    }

    @objc private func providerChanged() {
        providerDescription.stringValue = kind.indexOfSelectedItem == 1
            ? L("Thử nghiệm: dùng Magpie qua gateway loopback trên máy này. Cần gateway đang chạy và được cấu hình trước.", "Experimental: use Magpie through a loopback gateway on this Mac. The gateway must already be configured and running.")
            : L("Dùng tài khoản Claude Pro / Max. Đăng nhập riêng trong app mới, sau đó mở tab Code và tạo một phiên local.", "Use a Claude Pro / Max account. Sign in separately in the new app, then open the Code tab and create a local session.")
        showErrorMessage("")
    }

    private func setSubmitting(_ value: Bool) {
        submitting = value
        name.isEnabled = !value
        kind.isEnabled = !value
        cancelButton.isEnabled = !value
        submitButton.title = value ? L("Đang tạo…", "Creating…") : L("Tạo và mở", "Create and open")
        validate(showError: false)
    }

    private func close() {
        guard !closed else { return }
        closed = true
        submitButton.isEnabled = false
        if let sheet {
            sheet.sheetParent?.endSheet(sheet)
            sheet.orderOut(nil)
        }
        onClose?()
    }

    private func showErrorMessage(_ message: String) {
        errorLabel.stringValue = message
        guard let sheet, let content = sheet.contentView else { return }
        content.layoutSubtreeIfNeeded()
        sheet.setContentSize(NSSize(width: 520, height: max(390, content.fittingSize.height)))
    }

    func makeSheet() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 390),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = L("Thêm bản Claude", "Add a Claude App")
        window.isReleasedWhenClosed = false
        let content = NSView()
        window.contentView = content

        let title = NSTextField(labelWithString: L("Thêm bản Claude", "Add a Claude App"))
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let introduction = NSTextField(wrappingLabelWithString: L("Tách riêng công việc và tài khoản với một app Claude mới.", "Keep work and accounts separate with a new Claude app."))
        introduction.textColor = .secondaryLabelColor
        let nameLabel = NSTextField(labelWithString: L("Tên bản Claude", "Claude app name"))
        let kindLabel = NSTextField(labelWithString: L("Loại tài khoản", "Account type"))
        for label in [nameLabel, kindLabel] { label.font = .systemFont(ofSize: 13, weight: .semibold) }

        let form = NSStackView(views: [title, introduction, nameLabel, name, kindLabel, kind, providerDescription, errorLabel])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.setCustomSpacing(18, after: introduction)
        form.setCustomSpacing(16, after: name)
        form.setCustomSpacing(12, after: providerDescription)
        let spacer = NSView()
        let buttons = NSStackView(views: [spacer, cancelButton, submitButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let divider = NSBox()
        divider.boxType = .separator
        for view in [form, divider, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        for field in [introduction, name, kind, providerDescription, errorLabel] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        }
        errorLabel.preferredMaxLayoutWidth = 464
        providerDescription.preferredMaxLayoutWidth = 464
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 520),
            form.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            form.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            form.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            errorLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            divider.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 14),
            divider.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 16),
            buttons.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: form.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        window.setContentSize(NSSize(width: 520, height: content.fittingSize.height))
        window.initialFirstResponder = name
        name.nextKeyView = kind
        kind.nextKeyView = cancelButton
        cancelButton.nextKeyView = submitButton
        submitButton.nextKeyView = name
        self.sheet = window
        return window
    }
}
