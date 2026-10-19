// State shared between the stream session, the listener and the menu bar item.

import Foundation
import Network

struct StreamStats {
    var connected = false
    var width = 0, height = 0
    var bitrate = 0
    var fps = 0.0
    var encodeMs = 0.0, sendMs = 0.0
}

final class ServerState {
    private let lock = NSLock()
    private var _allowInput = false
    private var _stats = StreamStats()

    /// Whether the iMac may type and move the pointer on this Mac. Off at every start, switched on from the menu bar item.
    var allowInput: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _allowInput }
        set { lock.lock(); _allowInput = newValue; lock.unlock() }
    }

    var stats: StreamStats {
        get { lock.lock(); defer { lock.unlock() }; return _stats }
        set { lock.lock(); _stats = newValue; lock.unlock() }
    }
}

/// Counts failed handshakes per address and refuses an address for a while after too many.
/// Only touched on the main thread.
final class FailureTracker {
    let limit = 5
    let lockout: TimeInterval
    private var counts: [String: Int] = [:]
    private var blockedUntil: [String: Date] = [:]

    private let now: () -> Date      // the clock, so tests can move time

    /// The test suite shortens the lockout through the environment.
    init(lockout: TimeInterval? = nil, now: @escaping () -> Date = Date.init) {
        self.lockout = lockout ?? ProcessInfo.processInfo.environment["TBDISPLAY_LOCKOUT_SECONDS"].flatMap(Double.init) ?? 60
        self.now = now
    }

    /// A whole IPv6 /64 belongs to one machine, so it counts as one address. The address is parsed first, so
    /// compressed forms, letter case and an interface suffix such as "%en0" all give the same key.
    /// Refactored: TD-004 - this used to cut the text at the fourth colon, which "fe80::1" and "fe80:0:0:0::1" both evaded.
    static func key(for host: String) -> String {
        guard host.contains(":") else { return host }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        guard let address = IPv6Address(bare) else { return host }      // not an address: counted under its own spelling
        return address.rawValue.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func isBlocked(_ host: String) -> Bool {
        let host = Self.key(for: host)
        guard let until = blockedUntil[host] else { return false }
        if until > now() { return true }
        blockedUntil[host] = nil; counts[host] = nil
        return false
    }

    /// Returns true when this failure starts a lockout.
    func recordFailure(_ host: String) -> Bool {
        let host = Self.key(for: host)
        if counts.count > 1024 || blockedUntil.count > 1024 { counts.removeAll(); blockedUntil = blockedUntil.filter { $0.value > now() } }
        counts[host, default: 0] += 1
        guard counts[host]! >= limit else { return false }
        blockedUntil[host] = now().addingTimeInterval(lockout)
        counts[host] = 0
        return true
    }

    func recordSuccess(_ host: String) { counts[Self.key(for: host)] = nil }
}
