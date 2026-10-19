// What the iMac window says and shows, for every step of a connection.

import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runClientModelTests() {
    func model(_ events: ClientEvent...) -> ClientModel {
        var m = ClientModel()
        events.forEach { m.handle($0) }
        return m
    }

    let fresh = ClientModel()
    check(fresh.phase == .searching && fresh.statusMessage == "Looking for your MacBook…", "a new client says it is looking for the MacBook")
    check(fresh.presentation == .setupWindow, "a new client shows the setup window")

    let noKey = model(.keyMissing)
    check(noKey.phase == .needsKey, "a missing key means the client needs a key")
    check(noKey.statusMessage.contains("No pairing key") && noKey.statusMessage.contains("Pair"), "the message says to pair")
    check(model(.keyMissing, .keyFound).phase == .searching, "finding the key goes back to searching")
    check(model(.keyFound).phase == .searching, "a key found at start keeps searching")

    check(model(.connecting).phase == .connecting && model(.connecting).statusMessage == "Connecting…", "connecting says so")

    let waiting = model(.connecting, .dataReceived)
    check(waiting.phase == .waitingForPicture && waiting.statusMessage == "Connected. Waiting for the picture…", "data without a picture waits for the picture")
    check(waiting.presentation == .setupWindow, "the setup window stays up while waiting for the picture")

    let streaming = model(.connecting, .dataReceived, .pictureShown)
    check(streaming.phase == .streaming && streaming.statusMessage == "", "the first picture means streaming and no message")
    check(streaming.presentation == .fullScreen, "streaming shows the full-screen picture")
    check(model(.pictureShown).phase == .streaming, "a picture is enough to count as streaming")
    check(model(.connecting, .dataReceived, .pictureShown, .dataReceived).phase == .streaming, "more data never downgrades streaming")

    let lost = model(.connecting, .dataReceived, .pictureShown, .lost)
    check(lost.phase == .lost && lost.statusMessage == "Connection lost. Reconnecting…", "a lost link says so")
    check(lost.presentation == .setupWindow, "a lost link brings the setup window back")
    check(model(.pictureShown, .lost, .connecting).phase == .connecting, "reconnecting starts a new attempt")

    let refusedDefault = model(.connecting, .refused(nil))
    check(refusedDefault.phase == .refused, "a refusal is its own phase")
    check(refusedDefault.statusMessage == "The MacBook refused the connection. Check the pairing key and the cable. Retrying…", "the default refusal text")
    let tooOld = model(.connecting, .refused("This client is too old. Update it."))
    check(tooOld.statusMessage.contains("This client is too old. Update it."), "the MacBook's own reason is shown")
    check(!tooOld.statusMessage.contains("Check the pairing key"), "a given reason replaces the default advice")
    check(model(.refused("old reason"), .connecting).statusMessage == "Connecting…", "a new attempt clears the old reason")

    check(model(.connecting, .closed(hadData: false)).phase == .refused, "closing before any data counts as a refusal")
    check(model(.connecting, .refused("Update this client."), .closed(hadData: false)).statusMessage.contains("Update this client."), "the MacBook's reason survives the connection closing after it")
    check(model(.connecting, .dataReceived, .pictureShown, .closed(hadData: true)).phase == .lost, "closing after data counts as a lost link")

    check(model(.pictureShown, .keyMissing).phase == .needsKey && model(.pictureShown, .keyMissing).presentation == .setupWindow, "losing the key while streaming goes back to the setup window")

    // After a while with nothing from the MacBook the window gives advice about the cable
    let hint = "Check the cable is fully in at both ends"
    check(model(.stalled).statusMessage.hasPrefix("Looking for your MacBook…") && model(.stalled).statusMessage.contains(hint), "stalled while searching: the cable advice is added")
    check(model(.stalled).statusMessage.contains("try restarting this iMac"), "the advice mentions restarting the iMac after a replug")
    check(!model(.connecting).statusMessage.contains(hint), "no advice before the wait is long")
    check(model(.stalled, .connecting).statusMessage.hasPrefix("Connecting…") && model(.stalled, .connecting).statusMessage.contains(hint), "a new attempt does not clear the advice")
    check(model(.connecting, .dataReceived).statusMessage == "Connected. Waiting for the picture…", "data clears the advice")
    check(model(.stalled, .dataReceived, .pictureShown).statusMessage == "", "streaming has no advice")
    check(model(.stalled, .dataReceived, .lost).statusMessage == "Connection lost. Reconnecting…", "a lost link after data starts a fresh wait")
    check(model(.pictureShown, .lost, .stalled).statusMessage.contains(hint), "a lost link that stays lost gets the advice")
    check(!model(.keyMissing, .stalled).statusMessage.contains(hint), "a missing key keeps its own message")
    check(!model(.refused("This client is too old. Update it."), .stalled).statusMessage.contains(hint), "a reason from the MacBook is not buried in cable advice")
    check(model(.refused(nil), .stalled).statusMessage.contains(hint), "a refusal with no reason gets the cable advice too")
    check(model(.stalled).presentation == .setupWindow, "the advice appears in the setup window")

    let phases: [ClientEvent] = [.keyMissing, .keyFound, .connecting, .dataReceived, .lost, .refused(nil)]
    check(phases.allSatisfy { model($0).presentation == .setupWindow }, "only streaming is ever full screen")
}
