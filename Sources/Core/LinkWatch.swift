// A timeline for the next time the Thunderbolt link fails to come back: what the Mac did (slept, woke) and what the
// Thunderbolt Bridge did, each with a time in the log. Pure wording and change detection here, so it can be tested.
// The apps feed it from macOS notifications and a network path monitor (Sources/UI/PowerLog.swift).

import Foundation

enum PowerEvent: Equatable {
    case willSleep, didWake, displaysSlept, displaysWoke

    var text: String {
        switch self {
        case .willSleep: return "This Mac is going to sleep."
        case .didWake: return "This Mac woke up."
        case .displaysSlept: return "The display went to sleep."
        case .displaysWoke: return "The display woke up."
        }
    }
}

struct LinkWatch {
    private var last: Bool?

    /// A line for the log when the bridge's state is first seen or has changed. Nothing when it is unchanged.
    mutating func update(bridgeUp: Bool) -> String? {
        defer { last = bridgeUp }
        switch last {
        case nil: return bridgeUp ? "Thunderbolt Bridge is up." : "Thunderbolt Bridge is down."
        case bridgeUp?: return nil
        default: return bridgeUp ? "Thunderbolt Bridge came up." : "Thunderbolt Bridge went down."
        }
    }
}
