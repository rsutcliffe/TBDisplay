// What the "Open at login" control says and does in each state.

import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runLoginItemTests() {
    check(LoginItemState.off.title == "Open at login" && !LoginItemState.off.isChecked && LoginItemState.off.isEnabled, "off: unchecked and usable")
    check(LoginItemState.off.tapAction == .register, "off: a click switches it on")
    check(LoginItemState.on.title == "Open at login" && LoginItemState.on.isChecked && LoginItemState.on.isEnabled, "on: checked and usable")
    check(LoginItemState.on.tapAction == .unregister, "on: a click switches it off")
    check(LoginItemState.needsApproval.title.contains("Open at login") && LoginItemState.needsApproval.title.contains("System Settings"), "needs approval: the text says where to allow it")
    check(LoginItemState.needsApproval.isEnabled && LoginItemState.needsApproval.tapAction == .openSettings, "needs approval: a click opens System Settings")
    check(!LoginItemState.needsApproval.isChecked, "needs approval: not shown as on until it is allowed")
    check(!LoginItemState.unavailable.isEnabled && LoginItemState.unavailable.tapAction == .nothing, "unavailable: nothing to click")
    check(LoginItemState.unavailable.title.contains("Applications") && LoginItemState.unavailable.title.contains("reopen"), "unavailable: the text says to move the app to Applications and reopen it")
    check(LoginItemState(systemStatus: 0) == .off, "system: not registered is off")
    check(LoginItemState(systemStatus: 1) == .on, "system: enabled is on")
    check(LoginItemState(systemStatus: 2) == .needsApproval, "system: requires approval needs approval")
    check(LoginItemState(systemStatus: 3) == .off, "system: not found is off, because macOS says so for an app it has never registered")
    check(LoginItemState(systemStatus: 99) == .unavailable, "system: an unknown answer is unavailable")
}
