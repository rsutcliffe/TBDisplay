// Disconnect keeps the iMac out until the person lets it back in.

import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runConnectionGateTests() {
    var gate = ConnectionGate()
    check(gate.accepts && !gate.isPaused, "a new gate lets the iMac connect")
    gate.pause()
    check(!gate.accepts && gate.isPaused, "after Disconnect the iMac is refused")
    gate.pause()
    check(!gate.accepts, "pausing twice keeps it refused")
    gate.resume()
    check(gate.accepts && !gate.isPaused, "resuming lets the iMac connect again")
}
