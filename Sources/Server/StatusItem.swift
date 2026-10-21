// The menu bar item on the MacBook: shows what the server is doing and holds the few controls that matter.

import AppKit
import ApplicationServices

final class StatusController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let state: ServerState
    private let server: Server
    private var timer: Timer?
    private var shownConnected = false
    private var pairingPanel: PairingPanel?
    private lazy var reportWindow = ReportWindow()
    private lazy var checklistWindow = ChecklistWindow(role: .server) { [weak self] action in
        switch action {
        case .openSettings(let url): NSWorkspace.shared.open(url)
        case .startPairing: self?.pairNewMac()
        case .checkConnection: self?.checkConnection()
        }
    }

    init(state: ServerState, server: Server) {
        self.state = state
        self.server = server
        super.init()
        item.button?.image = MenuIcon.image(connected: false)
        item.button?.image?.accessibilityDescription = "TBDisplay"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let connected = self.state.stats.connected
            if connected != self.shownConnected {          // the big screen fills in while an iMac is connected
                self.shownConnected = connected
                self.item.button?.image = MenuIcon.image(connected: connected)
            }
            self.item.button?.appearsDisabled = !connected   // dim while waiting
        }
        item.button?.appearsDisabled = true
    }

    // Rebuilt each time the menu opens, so the numbers are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let stats = state.stats

        func line(_ text: String) {
            let entry = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            entry.isEnabled = false
            menu.addItem(entry)
        }
        func action(_ title: String, _ selector: Selector, enabled: Bool = true, checked: Bool = false) {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self
            entry.isEnabled = enabled
            entry.state = checked ? .on : .off
            menu.addItem(entry)
        }

        if stats.connected {
            line("Connected: \(stats.width) x \(stats.height)")
            line(String(format: "%d Mbps, %.0f fps", stats.bitrate / 1_000_000, stats.fps))
            line(String(format: "Encode %.0f ms, send %.0f ms", stats.encodeMs, stats.sendMs))
        } else if server.gate.isPaused {
            line("Paused. The iMac is refused")
        } else {
            line("Waiting for the iMac")
        }
        menu.addItem(.separator())
        action("Allow iMac keyboard and mouse", #selector(toggleInput), checked: state.allowInput)
        if server.gate.isPaused {
            action("Allow connections", #selector(resume))
        } else {
            action("Disconnect", #selector(disconnect), enabled: stats.connected)
        }
        menu.addItem(.separator())
        action("Pair a new Mac…", #selector(pairNewMac))
        action("Check connection…", #selector(checkConnection))
        action("Setup checklist…", #selector(showChecklist))
        let login = LoginItemControl.state
        action(login.title, #selector(toggleLogin), enabled: login.isEnabled, checked: login.isChecked)
        action("Show log in Finder", #selector(showLog))
        if let update = UpdateController.shared.available {
            action("Update available: TBDisplay \(update.version)…", #selector(openUpdate))
        }
        action("Check for updates…", #selector(checkForUpdates))
        action("Check for updates automatically", #selector(toggleAutomaticUpdates), checked: UpdateController.shared.automaticChecks)
        action("Reveal pairing key in Finder", #selector(revealKey))
        action("Create new pairing key…", #selector(newKey))
        menu.addItem(.separator())
        action("Quit TBDisplay", #selector(quit))
    }

    @objc private func toggleInput() {
        state.allowInput.toggle()
        if state.allowInput {
            log("Keyboard and mouse from the iMac are allowed.")
            if !AXIsProcessTrusted() {
                log("Posting input needs Accessibility permission. Add this app in System Settings > Privacy & Security > Accessibility.")
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
        } else {
            log("Keyboard and mouse from the iMac are blocked.")
        }
    }

    @objc private func disconnect() { server.disconnect() }

    @objc private func resume() { server.resume() }

    @objc private func checkForUpdates() { UpdateController.shared.checkNow() }

    @objc private func openUpdate() { UpdateController.shared.openDownloadPage() }

    @objc private func toggleAutomaticUpdates() { UpdateController.shared.automaticChecks.toggle() }

    @objc private func toggleLogin() { LoginItemControl.click() }

    @objc private func showLog() { LoginItemControl.revealLog(name: "server") }

    @objc private func checkConnection() { reportWindow.show() }

    @objc private func showChecklist() { checklistWindow.show() }

    /// At launch: the checklist opens by itself the first time, and again if something required stops being true.
    func showChecklistIfNeeded() { checklistWindow.showIfNeeded() }

    @objc private func pairNewMac() {
        let panel = pairingPanel ?? PairingPanel()
        panel.onClosed = { [weak self] in self?.pairingPanel = nil }
        pairingPanel = panel
        panel.open(key: server.pairingKey)
    }

    @objc private func revealKey() {
        NSWorkspace.shared.activateFileViewerSelecting([PairingKey.defaultURL])
    }

    @objc private func newKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Create a new pairing key?"
        alert.informativeText = "Every paired Mac is refused until you copy the new key to it. Use this if you think the key has been shared by mistake."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Create new key")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let key = try PairingKey.create()
            server.restart(key: key)
            log("Created a new pairing key. Copy it to the iMac.")
            revealKey()
        } catch {
            log("Could not create a new pairing key: \(error)")
        }
    }

    @objc private func quit() {
        server.shutdown { NSApp.terminate(nil) }
    }
}
