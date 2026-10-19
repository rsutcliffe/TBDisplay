// Small pieces of pairing logic with no windows or sockets, so they can be tested.

import Foundation

/// A counter for timers that must only act if nothing newer has started since they were set.
struct GenerationGate {
    private(set) var current = 0
    mutating func advance() -> Int { current += 1; return current }
    func isCurrent(_ generation: Int) -> Bool { generation == current }
}

struct PairingCandidate: Equatable {
    let name: String
    let interfaces: [String]
}

/// Which MacBook to pair with when several have their window open.
func choosePairingCandidate(_ candidates: [PairingCandidate]) -> PairingCandidate? {
    candidates.min { a, b in
        let aCable = a.interfaces.contains("bridge0"), bCable = b.interfaces.contains("bridge0")
        return aCable != bCable ? aCable : a.name < b.name
    }
}
