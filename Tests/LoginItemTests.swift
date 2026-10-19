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
    check(LoginItemState.unavailable.title.contains("installed"), "unavailable: the text says the app must be installed")
}
