// The first-run checklist: what each Mac still needs, in the order a new user should do it.

import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runChecklistTests() {
    let nothing = ChecklistState()
    let server = Checklist.items(role: .server, state: nothing)
    check(server.map(\.id) == ["screenRecording", "pairing", "accessibility", "link", "localNetwork"], "the MacBook list is in the order to do it")
    check(server.map(\.status) == [.todo, .todo, .todo, .unknown, .unknown], "with nothing known, three things are to do and the link and Local Network are unknown")
    check(server.map(\.required) == [true, true, false, false, false], "only Screen Recording and pairing are required")
    check(server.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty }, "every item says what it is and why")

    var linked = ChecklistState(); linked.linkUp = true
    var down = ChecklistState(); down.linkUp = false
    func item(_ id: String, role: ChecklistRole = .server, _ state: ChecklistState) -> ChecklistItem? {
        Checklist.items(role: role, state: state).first { $0.id == id }
    }
    check(item("screenRecording", nothing)?.action == .openSettings(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!), "Screen Recording opens its pane in System Settings")
    check(item("accessibility", nothing)?.action == .openSettings(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!), "Accessibility opens its pane")
    check(item("pairing", nothing)?.action == .startPairing && item("pairing", nothing)?.actionTitle == "Pair a new Mac…", "the MacBook offers to pair a new Mac")
    check(item("link", nothing)?.action == .checkConnection && item("link", nothing)?.actionTitle == "Check connection…", "an unknown link offers the connection check")
    check(item("link", down)?.action == .checkConnection, "a down link offers the connection check")
    check(item("link", linked)?.action == nil, "a working link needs no button")

    var granted = ChecklistState()
    granted.screenRecording = true
    check(item("screenRecording", granted)?.status == .done && item("screenRecording", granted)?.action == nil, "a granted permission is done and has no button")
    check(item("accessibility", granted)?.status == .todo, "granting one permission leaves the others alone")
    var withKey = granted; withKey.keyPresent = true
    check(item("pairing", withKey)?.status == .todo, "on the MacBook a key alone is not pairing: it exists from the first run")
    var withClient = granted; withClient.keyPresent = true; withClient.everConnected = true
    check(item("pairing", withClient)?.status == .done, "on the MacBook pairing is done once an iMac has connected")

    check(item("link", linked)?.status == .done && item("link", down)?.status == .todo && item("link", nothing)?.status == .unknown, "the link is done, to do, or unknown")

    // Completeness counts only the required items
    check(!Checklist.isComplete(server), "nothing done is not complete")
    check(Checklist.isComplete(Checklist.items(role: .server, state: withClient)), "the required items done is complete even without Accessibility")
    check(!Checklist.isComplete(Checklist.items(role: .server, state: granted)), "Screen Recording without pairing is not complete")

    // When to show it
    let complete = Checklist.items(role: .server, state: withClient)
    check(Checklist.shouldShowAtLaunch(firstRunDone: false, items: complete), "the very first launch always shows it")
    check(!Checklist.shouldShowAtLaunch(firstRunDone: true, items: complete), "a finished setup stays out of the way")
    check(Checklist.shouldShowAtLaunch(firstRunDone: true, items: server), "a revoked permission brings it back")

    // The iMac has a shorter list
    let imac = Checklist.items(role: .client, state: nothing)
    check(imac.map(\.id) == ["pairing", "link", "localNetwork"], "the iMac list is shorter")
    check(imac.first?.actionTitle == "Pair with MacBook…" && imac.first?.action == .startPairing, "the iMac offers to pair with the MacBook")
    check(imac.map(\.required) == [true, false, false], "on the iMac only pairing is required")
    var imacReady = ChecklistState(); imacReady.keyPresent = true
    check(Checklist.isComplete(Checklist.items(role: .client, state: imacReady)), "an iMac with a key is complete")
    check(Checklist.items(role: .client, state: imacReady).first?.status == .done, "on the iMac the key means pairing is done")
    check(imac.last?.status == .unknown && imac.last?.detail.contains("ask") == true, "Local Network says macOS will ask the first time")
}
