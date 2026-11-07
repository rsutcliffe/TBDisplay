// Whether the MacBook lets an iMac connect. Disconnect in the menu pauses it, because the client retries every
// second and would otherwise be back before the person has finished choosing.

import Foundation

struct ConnectionGate: Equatable {
    /// What an iMac is told when it arrives while this MacBook is paused.
    static let pausedNotice = "This MacBook has paused connections. Choose Allow connections in its menu bar item."
    private(set) var isPaused = false
    var accepts: Bool { !isPaused }
    mutating func pause() { isPaused = true }
    mutating func resume() { isPaused = false }
}
