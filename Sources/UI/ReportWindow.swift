// The "Connection check" window, used by both apps. The checking itself is DiagnosticsRunner and Diagnostics.

import AppKit

final class ReportWindow: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let textView = NSTextView()
    private let again = NSButton(title: "Check again", target: nil, action: nil)
    private let copy = NSButton(title: "Copy", target: nil, action: nil)
    private let close = NSButton(title: "Close", target: nil, action: nil)

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.title = "Connection check"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        for button in [again, copy, close] { button.bezelStyle = .rounded; button.target = self }
        again.action = #selector(runCheck); copy.action = #selector(copyReport); close.action = #selector(closeWindow)
        let buttons = NSStackView(views: [copy, again, close])
        buttons.spacing = 10

        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 12
        // A stack view used directly as the window's content ignored its right-hand margin, which left the Close button
        // touching the window edge. The margins are explicit constraints on a container instead.
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
        panel.contentView = container
        panel.center()
    }

    /// What the app adds to the cable report, worked out away from the main thread (the client really tries to connect).
    var extra: (() -> (findings: [Finding], outcome: ProbeOutcome?))?

    func show() {
        runCheck()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func runCheck() {
        textView.string = "Checking…\n\nThis takes up to 20 seconds."
        again.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async {
            let report = DiagnosticsRunner.run(appVersion: appVersion, protocolVersion: protocolVersion, extra: self.extra?() ?? ([], nil))
            DispatchQueue.main.async {
                self.textView.string = report
                self.again.isEnabled = true
            }
        }
    }

    @objc private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

    @objc private func closeWindow() { panel.performClose(nil) }
}
