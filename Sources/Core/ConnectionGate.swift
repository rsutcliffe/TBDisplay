// Whether the MacBook lets an iMac connect. Disconnect in the menu pauses it, because the client retries every
// second and would otherwise be back before the person has finished choosing.

import Foundation

struct ConnectionGate: Equatable {
    private(set) var isPaused = false
    var accepts: Bool { !isPaused }
    mutating func pause() { isPaused = true }
    mutating func resume() { isPaused = false }
}
