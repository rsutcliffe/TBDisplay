// The three ways the Macs can be joined, and what each one accepts.

import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runConnectionModeTests() {
    let tb = ConnectionMode.thunderbolt, wifi = ConnectionMode.wifi, eth = ConnectionMode.ethernet
    check(tb.allows(interfaceName: "bridge0", kind: .other) && tb.allows(interfaceName: "bridge0", kind: .wired), "Thunderbolt accepts the Thunderbolt Bridge, whatever kind macOS calls it")
    check(!tb.allows(interfaceName: "en0", kind: .wifi) && !tb.allows(interfaceName: "en5", kind: .wired), "Thunderbolt refuses Wi-Fi and Ethernet")
    check(wifi.allows(interfaceName: "en0", kind: .wifi) && !wifi.allows(interfaceName: "bridge0", kind: .other) && !wifi.allows(interfaceName: "en5", kind: .wired), "Wi-Fi accepts only Wi-Fi")
    check(eth.allows(interfaceName: "en5", kind: .wired) && eth.allows(interfaceName: "en4", kind: .wired), "Ethernet accepts a wired adapter, which includes a USB network link")
    check(!eth.allows(interfaceName: "bridge0", kind: .wired) && !eth.allows(interfaceName: "en0", kind: .wifi), "Ethernet does not take the Thunderbolt Bridge or Wi-Fi")
    check(ConnectionMode.allCases.allSatisfy { !$0.allows(interfaceName: "lo0", kind: .loopback) && !$0.allows(interfaceName: "utun3", kind: .other) }, "no mode accepts loopback or a tunnel")

    check(ConnectionMode.allCases.map(\.title) == ["Thunderbolt", "Wi-Fi", "Ethernet"], "the titles are the ones people see")
    check(ConnectionMode.allCases.allSatisfy { ConnectionMode(rawValue: $0.rawValue) == $0 }, "each mode survives being saved by name")

    let suite = UserDefaults(suiteName: "tbdisplay.test.connectionmode")!
    suite.removePersistentDomain(forName: "tbdisplay.test.connectionmode")
    check(ConnectionMode.saved(from: suite) == .thunderbolt, "nothing saved means Thunderbolt, so nobody is opened up by an upgrade")
    wifi.save(to: suite)
    check(ConnectionMode.saved(from: suite) == .wifi, "a saved mode is read back")
    suite.set("nonsense", forKey: Prefs.connectionMode)
    check(ConnectionMode.saved(from: suite) == .thunderbolt, "an unreadable saved value falls back to Thunderbolt")
    suite.removePersistentDomain(forName: "tbdisplay.test.connectionmode")

    check(InterfacePolicy.any.allows(interfaceName: "en9", kind: .other) && InterfacePolicy.any.allows(interfaceName: "lo0", kind: .loopback), "any accepts everything")
    check(InterfacePolicy.named("lo0").allows(interfaceName: "lo0", kind: .loopback) && !InterfacePolicy.named("lo0").allows(interfaceName: "en0", kind: .wifi), "a named interface accepts only that one")
    check(InterfacePolicy.mode(.wifi).allows(interfaceName: "en0", kind: .wifi) && !InterfacePolicy.mode(.wifi).allows(interfaceName: "bridge0", kind: .other), "a mode policy follows the mode")

    check(tb.refusalNotice == "This MacBook accepts Thunderbolt only. Change Connect over in its menu bar item, or move this iMac to Thunderbolt.", "the Thunderbolt refusal says what to do")
    check(wifi.refusalNotice.contains("accepts Wi-Fi only") && eth.refusalNotice.contains("accepts Ethernet only"), "each refusal names the mode that is accepted")
    check(InterfacePolicy.mode(.wifi).refusalNotice == wifi.refusalNotice, "a mode policy gives its mode's refusal")
    check(InterfacePolicy.named("en5").refusalNotice.contains("en5") && InterfacePolicy.named("en5").summary == "on en5", "a named policy says its name")
    check(InterfacePolicy.any.summary == "on any interface" && InterfacePolicy.mode(.thunderbolt).summary == "over Thunderbolt", "summaries read naturally in the log")
}
