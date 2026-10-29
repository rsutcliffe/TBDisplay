// Check connection, beyond the cable: what happened when this iMac really tried to reach the MacBook, and what the
// MacBook itself knows. Pure text and decisions only, so it can be tested. The network part is in Sources/Client.

import Foundation

enum ProbeOutcome: Equatable {
    case notSeen                      // Bonjour showed no MacBook at all
    case seenOnlyOther([String])      // seen, but only over other kinds of connection (their names)
    case noAnswer                     // found, but no connection within the time allowed
    case handshakeRefused             // found and answered, but the pairing key did not match
    case notice(String)               // connected, and the MacBook said why it will not stream
    case reachable                    // connected and accepted
}

enum ConnectionProbe {
    static func findings(_ outcome: ProbeOutcome, mode: ConnectionMode) -> [Finding] {
        switch outcome {
        case .reachable:
            return [Finding(level: .ok, title: "The MacBook answered",
                            detail: "This iMac can reach the MacBook over \(mode.title), and the pairing key matches.")]
        case .notSeen:
            return [Finding(level: .problem, title: "This iMac cannot see the MacBook",
                            detail: "Nothing answered over \(mode.title). Check that TBDisplay is running on the MacBook, that both Macs use the same Connect over setting, and that the cable or network is connected.")]
        case .seenOnlyOther(let kinds):
            let seen = kinds.count > 1 ? kinds.dropLast().joined(separator: ", ") + " and " + kinds.last! : kinds.first ?? "another connection"
            return [Finding(level: .problem, title: "The MacBook is visible, but not over \(mode.title)",
                            detail: "This iMac can see it over \(seen), but Connect over is set to \(mode.title). Change Connect over on both Macs, or check the cable.")]
        case .noAnswer:
            return [Finding(level: .problem, title: "The MacBook did not answer",
                            detail: "It was found, but it did not complete a connection in time. Restart TBDisplay on the MacBook. If that does not help, pair the Macs again.")]
        case .handshakeRefused:
            return [Finding(level: .problem, title: "The MacBook does not accept this iMac's pairing key",
                            detail: "Pair this iMac with the MacBook again (Pair with MacBook...).")]
        case .notice(let text):
            return [Finding(level: .problem, title: "The MacBook refused the connection", detail: text)]
        }
    }

    /// After Disconnect the client waits, and asks again every so often. Only an answer with nothing to say against it
    /// (no pause notice, no refusal) means the MacBook is allowing connections again.
    static func canReconnect(_ outcome: ProbeOutcome?) -> Bool { outcome == .reachable }

    /// When the MacBook answered, a cable complaint (another cable on USB 2, say) no longer matters: it becomes a note.
    static func reconcile(cable: [Finding], outcome: ProbeOutcome) -> [Finding] {
        guard outcome == .reachable else { return cable }
        return cable.map { finding in
            guard finding.level == .problem else { return finding }
            return Finding(level: .note, title: finding.title, detail: finding.detail + " The connection works, so this may be another cable.")
        }
    }
}

enum ServerStatus {
    static func findings(paused: Bool, policy: InterfacePolicy, everConnected: Bool) -> [Finding] {
        var found: [Finding] = []
        if paused {
            found.append(Finding(level: .problem, title: "Connections are paused",
                                 detail: "The iMac is being turned away. Choose Allow connections in this app's menu bar item."))
        }
        found.append(Finding(level: paused ? .note : .ok, title: "Accepting connections \(policy.summary)",
                             detail: "The iMac must use the same Connect over setting."))
        if !everConnected {
            found.append(Finding(level: .note, title: "No iMac has connected yet",
                                 detail: "Open TBDisplay on the iMac. If it is already open, pair the two Macs."))
        }
        return found
    }
}

enum InterfaceChoice {
    /// The first of this result's interfaces the policy accepts, as a position in the list.
    static func pick(_ interfaces: [(name: String, kind: InterfaceKind)], policy: InterfacePolicy) -> Int? {
        interfaces.firstIndex { policy.allows(interfaceName: $0.name, kind: $0.kind) }
    }
}
