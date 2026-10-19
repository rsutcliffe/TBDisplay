// The MacBook's pairing panel: shows the code and asks whether the iMac shows the same one.
// The wording comes from PairingFlowModel and the exchange itself from PairingHost.

import AppKit

final class PairingPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let status = NSTextField(wrappingLabelWithString: "")
    private let codeLabel = NSTextField(labelWithString: "")
    private let yes = NSButton(title: "Yes, it matches", target: nil, action: nil)
    private let no = NSButton(title: "No, they differ", target: nil, action: nil)
    private let close = NSButton(title: "Close", target: nil, action: nil)

    private var host: PairingHost?
    private var flow = PairingFlowModel(role: .host)
    private var shownCode: String { (flow.displayCode ?? "").replacingOccurrences(of: " ", with: "") }
    var onClosed: (() -> Void)?

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "Pair a new Mac"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.level = .floating
        panel.hidesOnDeactivate = false      // a panel hides when its app loses focus by default, which hid it while you looked at the iMac

        status.font = .systemFont(ofSize: 15)
        status.preferredMaxLayoutWidth = 390
        codeLabel.font = .monospacedDigitSystemFont(ofSize: 44, weight: .semibold)
        for button in [yes, no, close] { button.bezelStyle = .rounded; button.target = self }
        yes.action = #selector(confirmYes); no.action = #selector(confirmNo); close.action = #selector(closePanel)
        // No key equivalent on Yes: a stray Return must never release the key. It takes a deliberate click.

        let buttons = NSStackView(views: [yes, no, close])
        buttons.spacing = 10
        let stack = NSStackView(views: [status, codeLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        panel.contentView = stack
        panel.setContentSize(NSSize(width: 440, height: max(stack.fittingSize.height, 200)))
        panel.center()
    }

    /// Opens the panel and starts listening for the iMac. `key` is the MacBook's pairing key.
    func open(key: Data) {
        // A pairing window that is still running is kept: choosing the menu item again only brings the panel forward.
        // (Replacing it would race the old listener, which is still giving up the port.)
        if host != nil, !flow.isFinished {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        host?.onCode = nil; host?.onFinished = nil; host?.onReset = nil
        host?.stop()
        flow = PairingFlowModel(role: .host)
        let port = ProcessInfo.processInfo.environment["TBDISPLAY_PAIR_PORT"].flatMap(UInt16.init) ?? pairPort
        let host = PairingHost(pairingKey: key, port: port)
        host.onReset = { [weak self] in self?.flow.reset(); self?.refresh() }
        host.onCode = { [weak self] code in self?.flow.codeShown(code); self?.refresh() }
        host.onFinished = { [weak self] outcome in self?.flow.finished(outcome); self?.refresh() }
        do { try host.start(); self.host = host } catch {
            flow.finished(.failed("could not listen (\(error))"))
        }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func refresh() {
        status.stringValue = flow.statusText
        codeLabel.stringValue = flow.displayCode ?? ""
        codeLabel.isHidden = flow.displayCode == nil
        yes.isHidden = !flow.asksForConfirmation
        no.isHidden = !flow.asksForConfirmation
        close.title = flow.isFinished ? "Close" : "Cancel"
    }

    @objc private func confirmYes() { host?.confirm(true, code: shownCode) }
    @objc private func confirmNo() { host?.confirm(false, code: shownCode) }
    @objc private func closePanel() { panel.performClose(nil) }
    func windowWillClose(_ notification: Notification) {
        host?.onCode = nil; host?.onFinished = nil; host?.onReset = nil      // an old window must not repaint a newer one
        host?.stop(); host = nil
        onClosed?()
    }
}
