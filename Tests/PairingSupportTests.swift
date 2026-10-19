// Review items N2 and N4 of the second pairing review, and the latency statistics.

import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runPairingSupportTests() {
    // N2: a timer set for an old session must not act on a newer one
    var gate = GenerationGate()
    let first = gate.advance()
    check(gate.isCurrent(first), "a timer set now is current")
    let second = gate.advance()
    check(!gate.isCurrent(first), "a timer from before a new session is stale")
    check(gate.isCurrent(second), "the newest timer is current")
    check(first != second, "each session gets its own number")

    // N4: which MacBook to pair with
    let wifi = PairingCandidate(name: "Zed", interfaces: ["en0"])
    let cable = PairingCandidate(name: "Mac", interfaces: ["bridge0"])
    check(choosePairingCandidate([wifi, cable]) == cable, "the MacBook on the cable is chosen over one on Wi-Fi")
    check(choosePairingCandidate([PairingCandidate(name: "Zed", interfaces: ["bridge0"]), PairingCandidate(name: "Alpha", interfaces: ["bridge0"])])?.name == "Alpha", "two on the cable: the choice does not depend on arrival order")
    check(choosePairingCandidate([PairingCandidate(name: "Zed", interfaces: ["en0"]), PairingCandidate(name: "Alpha", interfaces: ["en0"])])?.name == "Alpha", "none on the cable: the choice is still in a fixed order")
    check(choosePairingCandidate([]) == nil, "no candidates gives no choice")

    // Latency statistics
    var stats = LatencyStats()
    check(stats.count == 0 && stats.average == 0 && stats.maximum == 0, "empty statistics are all zero")
    for v in [10.0, 20, 30, 40] { stats.add(v) }
    check(stats.count == 4, "the count follows the samples")
    check(stats.average == 25, "the average of 10 20 30 40 is 25")
    check(stats.maximum == 40, "the maximum is kept")
    var many = LatencyStats()
    for v in 1...100 { many.add(Double(v)) }
    check(many.percentile(0.95) == 95, "the 95th percentile of 1 to 100 is 95")
    check(stats.summary("encode") == "encode avg 25.0 ms, p95 40.0 ms, max 40.0 ms (4 frames)", "the summary reads as one line")
    stats.reset()
    check(stats.count == 0 && stats.summary("encode") == "encode: no frames", "reset empties the statistics")
}
