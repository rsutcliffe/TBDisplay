// The first-run checklist: what each Mac still needs, in the order a new user should do it.
// Pure logic from a snapshot of the Mac's state, so it is easy to test. The window only draws it.

import Foundation

enum ChecklistRole { case server, client }

struct ChecklistState {
    var screenRecording = false
    var accessibility = false
    var keyPresent = false
    var everConnected = false      // MacBook only: an iMac has connected at least once
    var linkUp: Bool? = nil        // nil when it is not known
}

enum ChecklistAction: Equatable {
    case openSettings(URL)
    case startPairing
    case checkConnection
}

struct ChecklistItem: Equatable {
    enum Status { case done, todo, unknown }
    let id: String
    let title: String
    let detail: String
    let status: Status
    let required: Bool
    let action: ChecklistAction?
    let actionTitle: String?
}

enum Checklist {
    private static func settings(_ pane: String) -> ChecklistAction {
        .openSettings(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    private static func item(_ id: String, _ title: String, _ detail: String, done: Bool?, required: Bool,
                             action: ChecklistAction?, actionTitle: String?, offerWhenUnknown: Bool = false) -> ChecklistItem {
        let status: ChecklistItem.Status = done == nil ? .unknown : (done! ? .done : .todo)
        let needsAction = status == .todo || (status == .unknown && offerWhenUnknown)
        return ChecklistItem(id: id, title: title, detail: detail, status: status, required: required,
                             action: needsAction ? action : nil, actionTitle: needsAction ? actionTitle : nil)
    }

    private static func link(_ state: ChecklistState) -> ChecklistItem {
        item("link", "Connect the cable",
             "A Thunderbolt 4 cable between the two Macs gives the best picture. Wi-Fi is fine for trying things out.",
             done: state.linkUp, required: false, action: .checkConnection, actionTitle: "Check connection…",
             offerWhenUnknown: true)       // the check is how you find out
    }

    private static func localNetwork(_ who: String) -> ChecklistItem {
        item("localNetwork", "Local Network",
             "macOS will ask the first time \(who). Choose Allow.",
             done: nil, required: false, action: nil, actionTitle: nil)
    }

    static func items(role: ChecklistRole, state: ChecklistState) -> [ChecklistItem] {
        switch role {
        case .server:
            return [
                item("screenRecording", "Allow Screen Recording",
                     "TBDisplay needs this to capture the extra display it creates. If you said no when macOS asked, turn it on in System Settings.",
                     done: state.screenRecording, required: true,
                     action: settings("Privacy_ScreenCapture"), actionTitle: "Open System Settings"),
                item("pairing", "Pair your iMac",
                     "Open the pairing window here, press Pair with MacBook on the iMac, and check that both show the same code.",
                     done: state.everConnected, required: true, action: .startPairing, actionTitle: "Pair a new Mac…"),
                item("accessibility", "Allow keyboard and mouse control (optional)",
                     "Only needed if you want the iMac's keyboard and mouse to control this Mac.",
                     done: state.accessibility, required: false,
                     action: settings("Privacy_Accessibility"), actionTitle: "Open System Settings"),
                link(state),
                localNetwork("an iMac connects"),
            ]
        case .client:
            return [
                item("pairing", "Pair this iMac with your MacBook",
                     "Press the button, then check that both Macs show the same code.",
                     done: state.keyPresent, required: true, action: .startPairing, actionTitle: "Pair with MacBook…"),
                link(state),
                localNetwork("this iMac connects"),
            ]
        }
    }

    /// Complete when everything required is done.
    static func isComplete(_ items: [ChecklistItem]) -> Bool {
        items.filter(\.required).allSatisfy { $0.status == .done }
    }

    /// Always on the very first launch. After that only when something required has stopped being true.
    static func shouldShowAtLaunch(firstRunDone: Bool, items: [ChecklistItem]) -> Bool {
        !firstRunDone || !isComplete(items)
    }
}
