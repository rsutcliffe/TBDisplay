// What each Mac says while pairing.

import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runPairingFlowModelTests() {
    var host = PairingFlowModel(role: .host)
    check(host.statusText.contains("Pair with MacBook"), "the MacBook tells you what to press on the iMac")
    check(host.displayCode == nil && !host.asksForConfirmation && !host.isFinished, "the MacBook starts with no code and no question")
    host.codeShown("482913")
    check(host.displayCode == "482 913", "the code is shown in two groups of three")
    check(host.asksForConfirmation, "the MacBook asks whether the codes match")
    check(host.statusText.contains("same code"), "the question mentions the same code")
    host.finished(.paired)
    check(host.isFinished && !host.asksForConfirmation, "a finished pairing stops asking")
    check(host.statusText == "Paired. The iMac can now connect.", "the MacBook confirms a pairing")

    func hostText(_ outcome: PairingOutcome) -> String { var m = PairingFlowModel(role: .host); m.finished(outcome); return m.statusText }
    check(hostText(.rejected) == "Pairing cancelled: the codes did not match. Nothing was shared.", "the MacBook explains a rejection")
    check(hostText(.expired) == "Pairing timed out. Open it again to try again.", "the MacBook explains a timeout")
    check(hostText(.tooManyFailures) == "Pairing stopped after too many failed attempts. Open it again to try again.", "the MacBook explains a lockout")
    check(hostText(.cancelled) == "Pairing cancelled.", "the MacBook explains a cancel")
    check(hostText(.failed("Something broke")) == "Pairing did not work: Something broke", "the MacBook shows a failure reason")

    // A session that ends clears the code and the question
    var dropped = PairingFlowModel(role: .host)
    dropped.codeShown("111222")
    dropped.reset()
    check(dropped.displayCode == nil && !dropped.asksForConfirmation && !dropped.isFinished, "a dropped session clears the code and the question")
    check(dropped.statusText.contains("Pair with MacBook"), "after a drop the MacBook waits for the next iMac")

    var guest = PairingFlowModel(role: .guest)
    check(guest.statusText == "Looking for a MacBook that is ready to pair…", "the iMac starts by looking")
    guest.codeShown("007001")
    check(guest.displayCode == "007 001", "leading zeros are kept")
    check(guest.asksForConfirmation, "the iMac asks too: both people check the code")
    check(guest.statusText == "Is this the same code as on your MacBook?", "the iMac asks whether the codes match")
    guest.finished(.paired)
    check(guest.statusText == "Paired. This iMac can now connect to the MacBook.", "the iMac confirms a pairing")
    func guestText(_ outcome: PairingOutcome) -> String { var m = PairingFlowModel(role: .guest); m.finished(outcome); return m.statusText }
    check(guestText(.rejected) == "The MacBook said the codes did not match. Nothing was saved.", "the iMac explains a rejection")
    check(guestText(.failed("The MacBook closed the connection.")) == "Pairing did not work: The MacBook closed the connection.", "the iMac shows a failure reason")
    check(guestText(.cancelled) == "Pairing cancelled.", "the iMac explains a cancel")
}
