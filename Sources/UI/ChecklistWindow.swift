// The setup checklist window, shared by both apps. What it lists comes from Checklist; this only draws it
// and passes a pressed button back as an action.

import AppKit
import ApplicationServices

enum ChecklistStateReader {
    /// A snapshot of this Mac. The link is read from the bridge, which is quick.
    static func read(role: ChecklistRole) -> ChecklistState {
        var state = ChecklistState()
        state.screenRecording = CGPreflightScreenCaptureAccess()
        state.accessibility = AXIsProcessTrusted()
        state.keyPresent = PairingKey.load() != nil
        state.everConnected = Prefs.defaults.bool(forKey: Prefs.everConnected)
        let bridge = DiagnosticsRunner.output(of: "/sbin/ifconfig", ["bridge0"], timeout: 3)
        switch Diagnostics.bridge(bridge).first?.level {
        case .ok?: state.linkUp = true
        case .problem?: state.linkUp = false
        default: state.linkUp = nil
        }
        return state
    }
}

final class ChecklistWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let role: ChecklistRole
    private let perform: (ChecklistAction) -> Void
    private let list = NSStackView()
    private var actions: [ChecklistAction] = []

    init(role: ChecklistRole, perform: @escaping (ChecklistAction) -> Void) {
        self.role = role
        self.perform = perform
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Setup checklist"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let heading = NSTextField(labelWithString: "Getting set up")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 14
        let again = NSButton(title: "Check again", target: self, action: #selector(refresh))
        let close = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        close.keyEquivalent = "\r"
        let buttons = NSStackView(views: [again, close])
        buttons.spacing = 10
        let stack = NSStackView(views: [heading, list, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        window.contentView = stack
        refresh()
        window.setContentSize(NSSize(width: 520, height: max(stack.fittingSize.height, 300)))
        window.center()
    }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Opens it at launch only when the checklist says it should be there.
    func showIfNeeded() {
        let items = Checklist.items(role: role, state: ChecklistStateReader.read(role: role))
        let firstRunDone = Prefs.defaults.bool(forKey: Prefs.firstRunDone)
        if Checklist.shouldShowAtLaunch(firstRunDone: firstRunDone, items: items) {
            log("Setup checklist: opening it (first run done: \(firstRunDone), complete: \(Checklist.isComplete(items))).")
            show()
        } else {
            log("Setup checklist: nothing left to do.")
        }
    }

    @objc func refresh() {
        let items = Checklist.items(role: role, state: ChecklistStateReader.read(role: role))
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        actions = []
        for item in items {
            let mark = NSTextField(labelWithString: item.status == .done ? "✓" : item.status == .todo ? "○" : "?")
            mark.font = .systemFont(ofSize: 16, weight: .bold)
            mark.textColor = item.status == .done ? .systemGreen : item.status == .todo ? .systemOrange : .secondaryLabelColor
            let title = NSTextField(labelWithString: item.title + (item.required ? "" : " "))
            title.font = .systemFont(ofSize: 14, weight: .semibold)
            let detail = NSTextField(wrappingLabelWithString: item.detail)
            detail.textColor = .secondaryLabelColor
            detail.preferredMaxLayoutWidth = 400
            var texts: [NSView] = [title, detail]
            if let action = item.action, let actionTitle = item.actionTitle {
                let button = NSButton(title: actionTitle, target: self, action: #selector(pressed(_:)))
                button.bezelStyle = .rounded
                button.tag = actions.count
                actions.append(action)
                texts.append(button)
            }
            let column = NSStackView(views: texts)
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 4
            let row = NSStackView(views: [mark, column])
            row.alignment = .top
            row.spacing = 10
            list.addArrangedSubview(row)
        }
    }

    @objc private func pressed(_ sender: NSButton) {
        guard sender.tag < actions.count else { return }
        perform(actions[sender.tag])
    }

    @objc private func closeWindow() { window.performClose(nil) }
    func windowWillClose(_ notification: Notification) { Prefs.defaults.set(true, forKey: Prefs.firstRunDone) }
}
