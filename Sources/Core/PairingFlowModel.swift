// What each Mac says while pairing: the MacBook's panel and the iMac's setup window both use this.

enum PairingRole { case host, guest }

struct PairingFlowModel {
    private let role: PairingRole
    private var code: String?
    private var outcome: PairingOutcome?

    init(role: PairingRole) { self.role = role }

    mutating func codeShown(_ code: String) { self.code = code }
    mutating func finished(_ outcome: PairingOutcome) { self.outcome = outcome }
    /// The guest went away: forget its code and start waiting again.
    mutating func reset() { code = nil }

    /// The code in two groups of three, so it is easy to compare by eye.
    var displayCode: String? {
        guard let code, code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    /// Both people check the code, so both Macs ask.
    var asksForConfirmation: Bool { code != nil && outcome == nil }

    var isFinished: Bool { outcome != nil }

    var statusText: String {
        if let outcome { return text(for: outcome) }
        switch (role, code) {
        case (.host, nil): return "On the iMac, open TBDisplay and press “Pair with MacBook…”. Waiting for it…"
        case (.host, _): return "Does the iMac show the same code?"
        case (.guest, nil): return "Looking for a MacBook that is ready to pair…"
        case (.guest, _): return "Is this the same code as on your MacBook?"
        }
    }

    private func text(for outcome: PairingOutcome) -> String {
        switch outcome {
        case .paired:
            return role == .host ? "Paired. The iMac can now connect." : "Paired. This iMac can now connect to the MacBook."
        case .rejected:
            return role == .host ? "Pairing cancelled: the codes did not match. Nothing was shared."
                                 : "The MacBook said the codes did not match. Nothing was saved."
        case .expired: return "Pairing timed out. Open it again to try again."
        case .tooManyFailures: return "Pairing stopped after too many failed attempts. Open it again to try again."
        case .cancelled: return "Pairing cancelled."
        case .failed(let why): return "Pairing did not work: \(why)"
        }
    }
}
