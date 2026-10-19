// The system side of "Open at login". The wording and the choice of action are in Sources/Core/LoginItem.swift.
// Registering is the person's own choice, made by clicking the control: nothing here registers on its own.

import AppKit
import ServiceManagement

enum LoginItemControl {
    static var state: LoginItemState {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .unavailable }
        let state = LoginItemState(systemStatus: SMAppService.mainApp.status.rawValue)
        if state == .unavailable { log("Open at login unavailable: system status \(SMAppService.mainApp.status.rawValue) for \(Bundle.main.bundlePath).") }
        return state
    }

    /// Does what a click on the control means in the current state.
    static func click() {
        switch state.tapAction {
        case .register:
            do { try SMAppService.mainApp.register(); log("Open at login: switched on.") }
            catch { log("Open at login could not be switched on: \(error.localizedDescription)") }
        case .unregister:
            do { try SMAppService.mainApp.unregister(); log("Open at login: switched off.") }
            catch { log("Open at login could not be switched off: \(error.localizedDescription)") }
        case .openSettings:
            SMAppService.openSystemSettingsLoginItems()
        case .nothing:
            break
        }
    }

    static func revealLog(name: String) {
        NSWorkspace.shared.activateFileViewerSelecting([LogFile.defaultURL(name: name)])
    }
}
