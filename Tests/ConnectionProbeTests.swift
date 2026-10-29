// Check connection says one plain reason and one action, from what really happened.

import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runConnectionProbeTests() {
    let tb = ConnectionMode.thunderbolt, wifi = ConnectionMode.wifi
    func one(_ outcome: ProbeOutcome, _ mode: ConnectionMode = .thunderbolt) -> Finding? {
        let found = ConnectionProbe.findings(outcome, mode: mode)
        return found.count == 1 ? found[0] : nil
    }

    check(one(.reachable)?.level == .ok && one(.reachable)?.title == "The MacBook answered", "reachable: one OK finding")
    check(one(.reachable, wifi)?.detail.contains("Wi-Fi") == true, "reachable: names the connection used")
    check(one(.notSeen)?.level == .problem && one(.notSeen)?.title == "This iMac cannot see the MacBook", "not seen: a problem with a plain title")
    check(one(.notSeen)?.detail.contains("TBDisplay is running on the MacBook") == true && one(.notSeen)?.detail.contains("Thunderbolt") == true, "not seen: says what to check and which connection was tried")
    check(one(.seenOnlyOther(["Wi-Fi"]))?.title == "The MacBook is visible, but not over Thunderbolt", "other only: the title says which connection is missing")
    check(one(.seenOnlyOther(["Wi-Fi", "Ethernet"]))?.detail.contains("Wi-Fi and Ethernet") == true, "other only: lists what was seen")
    check(one(.seenOnlyOther(["Wi-Fi"]))?.detail.contains("Change Connect over on both Macs") == true, "other only: says what to do")
    check(one(.noAnswer)?.level == .problem && one(.noAnswer)?.detail.contains("Restart TBDisplay on the MacBook") == true, "no answer: says to restart the MacBook app")
    check(one(.handshakeRefused)?.detail.contains("Pair with MacBook") == true, "handshake refused: points at pairing again")
    let paused = ConnectionGate.pausedNotice
    check(one(.notice(paused))?.level == .problem && one(.notice(paused))?.detail == paused, "a notice is passed on word for word")
    check(one(.notice(paused))?.title == "The MacBook refused the connection", "a notice has one title whatever it says")

    check(ConnectionGate.pausedNotice == "This MacBook has paused connections. Choose Allow connections in its menu bar item.", "the pause notice says what to do")

    let usb = Finding(level: .problem, title: "The other Mac is connected over USB 2 only", detail: "x")
    let none = Finding(level: .problem, title: "No Thunderbolt device on any port", detail: "y")
    let ok = Finding(level: .ok, title: "Thunderbolt link found", detail: "z")
    let moot = ConnectionProbe.reconcile(cable: [usb, none, ok], outcome: .reachable)
    check(moot.map(\.level) == [.note, .note, .ok], "reachable: cable problems become notes and the rest is kept")
    check(moot[0].title == usb.title && moot[0].detail.contains("The connection works") , "reachable: the note says the connection works anyway")
    check(ConnectionProbe.reconcile(cable: [usb], outcome: .noAnswer) == [usb], "any other outcome leaves the cable findings alone")

    let stopped = ServerStatus.findings(paused: true, policy: .mode(.thunderbolt), everConnected: true)
    check(stopped.first?.level == .problem && stopped.first?.title == "Connections are paused" && stopped.first?.detail.contains("Allow connections") == true, "server paused: first and a problem")
    let normal = ServerStatus.findings(paused: false, policy: .mode(.wifi), everConnected: true)
    check(normal.count == 1 && normal[0].level == .ok && normal[0].title == "Accepting connections over Wi-Fi" && normal[0].detail.contains("same Connect over"), "server normal: one OK line naming the connection")
    let fresh = ServerStatus.findings(paused: false, policy: .any, everConnected: false)
    check(fresh.contains { $0.level == .note && $0.title == "No iMac has connected yet" }, "server never connected: a note")
    check(ServerStatus.findings(paused: false, policy: .named("en5"), everConnected: true).first?.title == "Accepting connections on en5", "server named interface: says the name")

    let cases: [(name: String, kind: InterfaceKind)] = [("en0", .wifi), ("bridge0", .other), ("en5", .wired)]
    check(InterfaceChoice.pick(cases, policy: .mode(.thunderbolt)) == 1, "choice: Thunderbolt picks the bridge")
    check(InterfaceChoice.pick(cases, policy: .mode(.wifi)) == 0, "choice: Wi-Fi picks the Wi-Fi interface")
    check(InterfaceChoice.pick(cases, policy: .mode(.ethernet)) == 2, "choice: Ethernet picks the wired adapter")
    check(InterfaceChoice.pick([("en0", .wifi)], policy: .mode(.thunderbolt)) == nil, "choice: nothing acceptable gives nothing")
    check(InterfaceChoice.pick(cases, policy: .any) == 0 && InterfaceChoice.pick([], policy: .any) == nil, "choice: any takes the first, and an empty list gives nothing")

    let model = { () -> ClientModel in var m = ClientModel(); m.handle(.stalled); return m }()
    check(model.statusMessage.hasSuffix("Press Check connection to find out why."), "the long-wait advice points at Check connection")

    // A client that was told Disconnect reconnects by itself, but only once the MacBook is really allowing connections
    check(ConnectionProbe.canReconnect(.reachable), "ended: an answer with no notice means reconnect")
    check(!ConnectionProbe.canReconnect(.notice(ConnectionGate.pausedNotice)), "ended: still paused means wait")
    check(!ConnectionProbe.canReconnect(.notSeen) && !ConnectionProbe.canReconnect(.seenOnlyOther(["Wi-Fi"])) && !ConnectionProbe.canReconnect(.noAnswer) && !ConnectionProbe.canReconnect(.handshakeRefused), "ended: anything but a clean answer means wait")
    check(!ConnectionProbe.canReconnect(nil), "ended: no outcome (no key) means wait")
    var ended = ClientModel(); ended.handle(.endedByMacBook)
    check(ended.statusMessage.contains("reconnects by itself") && ended.statusMessage.contains("press Reconnect"), "ended: the window says it reconnects by itself, or press Reconnect now")
}
