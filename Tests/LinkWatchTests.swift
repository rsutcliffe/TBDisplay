// The timeline in the logs: sleeping, waking and the Thunderbolt Bridge going up or down.

import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runLinkWatchTests() {
    var watch = LinkWatch()
    check(watch.update(bridgeUp: true) == "Thunderbolt Bridge is up.", "the first sighting is logged: up")
    check(watch.update(bridgeUp: true) == nil, "no change, no line")
    check(watch.update(bridgeUp: false) == "Thunderbolt Bridge went down.", "going down is logged")
    check(watch.update(bridgeUp: false) == nil, "still down, no line")
    check(watch.update(bridgeUp: true) == "Thunderbolt Bridge came up.", "coming back up is logged")

    var down = LinkWatch()
    check(down.update(bridgeUp: false) == "Thunderbolt Bridge is down.", "the first sighting is logged: down")

    check(PowerEvent.willSleep.text == "This Mac is going to sleep.", "sleep wording")
    check(PowerEvent.didWake.text == "This Mac woke up.", "wake wording")
    check(PowerEvent.displaysSlept.text == "The display went to sleep.", "display sleep wording")
    check(PowerEvent.displaysWoke.text == "The display woke up.", "display wake wording")

    func model(_ events: ClientEvent...) -> ClientModel { var m = ClientModel(); events.forEach { m.handle($0) }; return m }
    check(model(.dataReceived, .pictureShown).keepsDisplayAwake, "streaming holds the iMac awake")
    check(!model().keepsDisplayAwake && !model(.connecting).keepsDisplayAwake, "searching or connecting does not")
    check(!model(.dataReceived).keepsDisplayAwake, "waiting for the first picture does not")
    check(!model(.dataReceived, .pictureShown, .lost).keepsDisplayAwake, "a lost link lets the iMac sleep")
    check(!model(.dataReceived, .pictureShown, .endedByMacBook).keepsDisplayAwake, "after Disconnect the iMac may sleep")
    check(!model(.refused("x")).keepsDisplayAwake && !model(.keyMissing).keepsDisplayAwake, "refused or no key does not")

    // The advice names the menu this macOS really has, not a + button it does not
    let note = Diagnostics.advice([Finding(level: .problem, title: "Thunderbolt Bridge is not active", detail: "x")]).first?.detail ?? ""
    check(!note.contains("+ button"), "the advice no longer mentions a + button")
    check(note.contains("add it again from the same ... menu"), "the advice says to add it again from the same menu")
}
