// Whether the app opens by itself when the person logs in, and what the menu says about it.
// The system call lives in Sources/UI/LoginItemControl.swift. This part only decides the wording and the action.

import Foundation

enum LoginItemState: Equatable {
    case on, off
    case needsApproval       // registered, but the person has to allow it in System Settings
    case unavailable         // not running as an installed app, so macOS has no login item to make
}

enum LoginItemAction: Equatable { case register, unregister, openSettings, nothing }

extension LoginItemState {
    var title: String {
        switch self {
        case .on, .off: return "Open at login"
        case .needsApproval: return "Open at login (allow it in System Settings)"
        case .unavailable: return "Open at login (the app must be installed first)"
        }
    }
    var isChecked: Bool { self == .on }
    var isEnabled: Bool { self != .unavailable }
    var tapAction: LoginItemAction {
        switch self {
        case .off: return .register
        case .on: return .unregister
        case .needsApproval: return .openSettings
        case .unavailable: return .nothing
        }
    }
}
