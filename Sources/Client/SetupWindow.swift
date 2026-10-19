// The iMac client's setup window: what is happening, and the few things a person might need to press.
// Shown whenever the client is not streaming. The wording comes from ClientModel.

import AppKit

final class SetupWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let status = NSTextField(wrappingLabelWithString: "")
    private let keyLine = NSTextField(labelWithString: "")
    let pairButton = NSButton(title: "Pair with MacBook…", target: nil, action: nil)
    let checkButton = NSButton(title: "Check connection…", target: nil, action: nil)
    let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    let logButton = NSButton(title: "Show log", target: nil, action: nil)
    let updateButton = NSButton(title: "Check for updates…", target: nil, action: nil)
    let autoUpdateBox = NSButton(checkboxWithTitle: "Check for updates automatically", target: nil, action: nil)
    private let updateLabel = NSTextField(labelWithString: "")
    let loginBox = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)
    var onQuit: (() -> Void)?
    var onCheck: (() -> Void)?
    var onPairingAnswer: ((Bool) -> Void)?
    private let yesButton = NSButton(title: "Yes, it matches", target: nil, action: nil)
    private let noButton = NSButton(title: "No, they differ", target: nil, action: nil)
    private let codeLabel = NSTextField(labelWithString: "")
    private var lastModel = ClientModel()
    var pairing: PairingFlowModel? { didSet { update(lastModel) } }

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "TBDisplay"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let title = NSTextField(labelWithString: "TBDisplay")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        status.font = .systemFont(ofSize: 15)
        keyLine.textColor = .secondaryLabelColor
        let version = NSTextField(labelWithString: "Version \(appVersion)")
        version.textColor = .secondaryLabelColor
        for button in [pairButton, checkButton, quitButton, logButton, updateButton, yesButton, noButton] { button.bezelStyle = .rounded }
        updateButton.target = self; updateButton.action = #selector(updatePressed)
        autoUpdateBox.target = self; autoUpdateBox.action = #selector(toggleAutomaticUpdates)
        updateLabel.textColor = .systemBlue
        UpdateController.shared.onChange = { [weak self] in self?.refreshUpdateRow() }
        refreshUpdateRow()
        logButton.target = self; logButton.action = #selector(showLog)
        loginBox.target = self; loginBox.action = #selector(toggleLogin)
        yesButton.target = self; yesButton.action = #selector(answerYes)
        noButton.target = self; noButton.action = #selector(answerNo)
        yesButton.isHidden = true; noButton.isHidden = true
        quitButton.target = self
        quitButton.action = #selector(quit)
        quitButton.keyEquivalent = "\r"
        codeLabel.font = .monospacedDigitSystemFont(ofSize: 44, weight: .semibold)
        codeLabel.isHidden = true
        checkButton.target = self
        checkButton.action = #selector(check)

        let buttons = NSStackView(views: [pairButton, checkButton, updateButton, logButton, quitButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let answers = NSStackView(views: [yesButton, noButton])
        answers.orientation = .horizontal
        answers.spacing = 10
        let stack = NSStackView(views: [title, status, codeLabel, answers, keyLine, version, updateLabel, loginBox, autoUpdateBox, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.setCustomSpacing(24, after: version)
        // The window is sized from a real layout pass, so the widest row (the buttons) always has its margin on the right,
        // and the status text wraps at the window's width instead of a fixed one.
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
            status.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -48),
        ])
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        // The engine's own width left out the right-hand margin of the button row, so the width is worked out here: the widest row plus both margins.
        let width = max(520, buttons.fittingSize.width + stack.edgeInsets.left + stack.edgeInsets.right)
        window.setContentSize(NSSize(width: width, height: max(container.fittingSize.height, 240)))
        window.center()
    }

    func update(_ model: ClientModel) {
        lastModel = model
        // While pairing, its wording and code take over from the connection status.
        status.stringValue = pairing?.statusText ?? model.statusMessage
        codeLabel.stringValue = pairing?.displayCode ?? ""
        codeLabel.isHidden = pairing?.displayCode == nil
        pairButton.isEnabled = pairing == nil || pairing?.isFinished == true
        let asking = pairing?.asksForConfirmation == true
        yesButton.isHidden = !asking
        noButton.isHidden = !asking
        keyLine.stringValue = PairingKey.load() == nil ? "Pairing key: not on this Mac" : "Pairing key: found"
        refreshLoginBox()
    }

    private func refreshLoginBox() {
        let login = LoginItemControl.state
        loginBox.title = login.title
        loginBox.state = login.isChecked ? .on : .off
        loginBox.isEnabled = login.isEnabled
    }

    /// Shows the known update, if any, and keeps the button and the tick box in step with it.
    private func refreshUpdateRow() {
        if let release = UpdateController.shared.available {
            updateLabel.stringValue = "TBDisplay \(release.version) is available (you have \(appVersion))."
            updateButton.title = "Download \(release.version)…"
        } else {
            updateLabel.stringValue = ""
            updateButton.title = "Check for updates…"
        }
        updateLabel.isHidden = updateLabel.stringValue.isEmpty
        autoUpdateBox.state = UpdateController.shared.automaticChecks ? .on : .off
    }

    @objc private func updatePressed() {
        if UpdateController.shared.available != nil { UpdateController.shared.openDownloadPage() } else { UpdateController.shared.checkNow() }
    }
    @objc private func toggleAutomaticUpdates() { UpdateController.shared.automaticChecks = (autoUpdateBox.state == .on) }
    @objc private func toggleLogin() { LoginItemControl.click(); refreshLoginBox() }
    @objc private func showLog() { LoginItemControl.revealLog(name: "client") }
    @objc private func answerYes() { onPairingAnswer?(true) }
    @objc private func answerNo() { onPairingAnswer?(false) }
    @objc private func quit() { onQuit?() }
    @objc private func check() { onCheck?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { onQuit?(); return false }
}
