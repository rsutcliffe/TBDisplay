// Pairing between two real network endpoints on this Mac: the host (MacBook) and the guest (iMac).

import Foundation
import Network
#if canImport(TBCore)
@testable import TBCore
#endif

/// Waits up to `seconds` for the condition, polling.
func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return condition()
}

/// Thread-safe holder for what a callback reported.
final class Box<T> {
    private let lock = NSLock()
    private var stored: T?
    var value: T? { get { lock.lock(); defer { lock.unlock() }; return stored } set { lock.lock(); stored = newValue; lock.unlock() } }
}

func runPairingNetworkTests() {
    let queue = DispatchQueue(label: "pairing-tests")
    let pairingKey = Data((0..<32).map { UInt8($0 &* 5 &+ 11) })
    var port: UInt16 = 47810
    func nextPort() -> UInt16 { port += 1; return port }

    struct Pair {
        let host: PairingHost, guest: PairingGuest
        let hostCode = Box<String>(), guestCode = Box<String>()
        let hostOutcome = Box<PairingOutcome>(), guestOutcome = Box<PairingOutcome>()
        let keyURL: URL
    }
    func makePair(window: TimeInterval = 20, maxFailures: Int = 3) -> (Pair, UInt16)? {
        let p = nextPort()
        let dir = makeTempDir()
        let keyURL = dir.appendingPathComponent("pairing-key")
        let host = PairingHost(pairingKey: pairingKey, port: p, window: window, maxFailures: maxFailures, advertise: false, callbackQueue: queue)
        let guest = PairingGuest(host: "127.0.0.1", port: p, keyURL: keyURL, timeout: 20, callbackQueue: queue)
        let pair = Pair(host: host, guest: guest, keyURL: keyURL)
        host.onCode = { pair.hostCode.value = $0 }
        guest.onCode = { pair.guestCode.value = $0 }
        host.onFinished = { pair.hostOutcome.value = $0 }
        guest.onFinished = { pair.guestOutcome.value = $0 }
        do { try host.start() } catch { return nil }
        return (pair, p)
    }

    // A key from pairing is stored privately and reads back
    do {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tbdisplay/pairing-key")
        try? PairingKey.store(pairingKey, at: url)
        check(PairingKey.load(from: url) == pairingKey, "a stored key reads back")
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
        check(mode == 0o600, "a stored key is owner-only")
    }

    // The happy path
    if let (pair, _) = makePair() {
        pair.guest.start()
        let bothShowCode = waitUntil(5) { pair.hostCode.value != nil && pair.guestCode.value != nil }
        check(bothShowCode, "both sides get a code")
        check(pair.hostCode.value == pair.guestCode.value && pair.hostCode.value?.count == 6, "the two codes are the same six digits")
        check(!FileManager.default.fileExists(atPath: pair.keyURL.path), "no key is stored before the person confirms")
        pair.host.confirm(true, code: pair.hostCode.value ?? "")
        check(waitUntil(5) { pair.hostOutcome.value == .paired }, "the MacBook finishes once its person confirms")
        _ = waitUntil(0.5) { false }
        check(!FileManager.default.fileExists(atPath: pair.keyURL.path) && pair.guestOutcome.value == nil, "the iMac stores nothing until its own person confirms")
        pair.guest.confirm(true)
        check(waitUntil(5) { pair.guestOutcome.value == .paired }, "confirming on both sides pairs them")
        check(PairingKey.load(from: pair.keyURL) == pairingKey, "the iMac stores exactly the MacBook's key")
        pair.host.stop()
    } else { check(false, "the host starts") }

    // The iMac person says the codes differ, after the MacBook person said they match
    if let (pair, _) = makePair() {
        pair.guest.start()
        _ = waitUntil(5) { pair.hostCode.value != nil }
        pair.host.confirm(true, code: pair.hostCode.value ?? "")
        _ = waitUntil(1) { false }
        pair.guest.confirm(false)
        check(waitUntil(5) { pair.guestOutcome.value == .rejected }, "the iMac person can refuse after the MacBook agreed")
        check(!FileManager.default.fileExists(atPath: pair.keyURL.path), "a key the iMac person refused is never stored")
        pair.host.stop()
    } else { check(false, "the host starts") }

    // The person says the codes differ
    if let (pair, _) = makePair() {
        pair.guest.start()
        _ = waitUntil(5) { pair.hostCode.value != nil }
        pair.host.confirm(false, code: pair.hostCode.value ?? "")
        check(waitUntil(5) { pair.guestOutcome.value == .rejected && pair.hostOutcome.value == .rejected }, "saying no rejects on both sides")
        check(!FileManager.default.fileExists(atPath: pair.keyURL.path), "a rejected pairing stores no key")
        pair.host.stop()
    } else { check(false, "the host starts") }

    // The window closes by itself
    if let (pair, _) = makePair(window: 0.5) {
        check(waitUntil(3) { pair.hostOutcome.value == .expired }, "an unused pairing window expires")
        pair.host.stop()
    } else { check(false, "the host starts") }

    // Garbage from the network counts as failures and shuts pairing
    if let (pair, p) = makePair(maxFailures: 3) {
        for _ in 0..<3 {
            let junk = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: p)!, using: .tcp)
            junk.start(queue: queue)
            junk.send(content: frameMessage(.pairCommit, Data(count: 5)), completion: .idempotent)   // a commit of the wrong size
            _ = waitUntil(0.4) { false }
            junk.cancel()
        }
        check(waitUntil(3) { pair.hostOutcome.value == .tooManyFailures }, "three bad attempts close the pairing window")
        pair.host.stop()
    } else { check(false, "the host starts") }

    // Only one session at a time
    if let (pair, p) = makePair() {
        pair.guest.start()
        _ = waitUntil(5) { pair.hostCode.value != nil }
        let other = PairingGuest(host: "127.0.0.1", port: p, keyURL: pair.keyURL.deletingLastPathComponent().appendingPathComponent("other"), timeout: 5, callbackQueue: queue)
        let otherOutcome = Box<PairingOutcome>()
        other.onFinished = { otherOutcome.value = $0 }
        other.start()
        check(waitUntil(5) { otherOutcome.value != nil && otherOutcome.value != .paired }, "a second guest during a session is turned away")
        pair.host.confirm(true, code: pair.hostCode.value ?? "")
        pair.guest.confirm(true)
        check(waitUntil(5) { pair.guestOutcome.value == .paired }, "the first guest still pairs")
        pair.host.stop()
    } else { check(false, "the host starts") }


    // A rogue "MacBook" with no person behind it sends a key as soon as it is asked: the iMac must not keep it
    do {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let rogueKey = Data(repeating: 0xEE, count: 32)
        let p = nextPort()
        let listener = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: p)!)
        let rogueQueue = DispatchQueue(label: "rogue")
        var responder = PairingResponder(pairingKey: rogueKey)
        listener?.newConnectionHandler = { conn in
            conn.start(queue: rogueQueue)
            receiveMessages(on: conn, maxMessage: 256, onMessage: { type, payload in
                switch MessageType(rawValue: type) {
                case .pairCommit:
                    if let reply = try? responder.receiveCommit(payload) { conn.send(content: frameMessage(.pairResponse, reply), completion: .idempotent) }
                case .pairReveal:
                    _ = try? responder.receiveReveal(payload)          // no person is ever asked
                    if let sealed = try? responder.sealedKey() { conn.send(content: frameMessage(.pairSealed, sealed), completion: .idempotent) }
                default: break
                }
            }, onClose: { _ in })
        }
        listener?.start(queue: rogueQueue)
        let keyURL = dir.appendingPathComponent("pairing-key")
        let guest = PairingGuest(host: "127.0.0.1", port: p, keyURL: keyURL, timeout: 3, callbackQueue: queue)
        let outcome = Box<PairingOutcome>()
        guest.onFinished = { outcome.value = $0 }
        guest.start()
        _ = waitUntil(1.5) { false }
        check(!FileManager.default.fileExists(atPath: keyURL.path), "a key from a MacBook nobody confirmed is not stored without the iMac person's yes")
        check(waitUntil(5) { outcome.value != nil && outcome.value != .paired }, "unanswered, the iMac gives up without pairing")
        check(!FileManager.default.fileExists(atPath: keyURL.path), "and still stores nothing")
        listener?.cancel()
    }

    // Finding 1 of the review: a second "MacBook" answer must not give the iMac a second code
    do {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let p = nextPort()
        let listener = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: p)!)
        let rogueQueue = DispatchQueue(label: "rogue2")
        listener?.newConnectionHandler = { conn in
            conn.start(queue: rogueQueue)
            var first = PairingResponder(pairingKey: Data(count: 32))
            var second = PairingResponder(pairingKey: Data(count: 32))
            receiveMessages(on: conn, maxMessage: 256, onMessage: { type, payload in
                if MessageType(rawValue: type) == .pairCommit {
                    if let a = try? first.receiveCommit(payload) { conn.send(content: frameMessage(.pairResponse, a), completion: .idempotent) }
                    // A second answer to the same commit, with other values, as a man in the middle would send
                    if let b = try? second.receiveCommit(payload) { conn.send(content: frameMessage(.pairResponse, b), completion: .idempotent) }
                }
            }, onClose: { _ in })
        }
        listener?.start(queue: rogueQueue)
        let guest = PairingGuest(host: "127.0.0.1", port: p, keyURL: dir.appendingPathComponent("k"), timeout: 3, callbackQueue: queue)
        let codes = Box<[String]>(); codes.value = []
        let outcome = Box<PairingOutcome>()
        guest.onCode = { codes.value = (codes.value ?? []) + [$0] }
        guest.onFinished = { outcome.value = $0 }
        guest.start()
        _ = waitUntil(2) { outcome.value != nil }
        check((codes.value ?? []).count <= 1, "the iMac never shows a second code for one pairing")
        check(outcome.value != nil && outcome.value != .paired, "a second answer ends the pairing instead of changing the code")
        listener?.cancel()
    }

    // Finding 2: starting a session and walking away costs the attacker a failure each time
    if let (pair, p) = makePair(maxFailures: 3) {
        for _ in 0..<3 {
            var initiator = PairingInitiator()
            let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: p)!, using: .tcp)
            conn.start(queue: queue)
            conn.send(content: frameMessage(.pairCommit, initiator.commitMessage()), completion: .idempotent)
            _ = waitUntil(0.4) { false }          // the host answers with its key and nonce, and the walk-away follows
            _ = initiator
            conn.cancel()
            _ = waitUntil(0.3) { false }
        }
        check(waitUntil(3) { pair.hostOutcome.value == .tooManyFailures }, "three walk-aways before the reveal close the pairing window")
        pair.host.stop()
    } else { check(false, "the host starts") }

    // Finding 3: a Yes belongs to the code that was shown
    if let (pair, _) = makePair() {
        pair.guest.start()
        _ = waitUntil(5) { pair.hostCode.value != nil }
        pair.host.confirm(true, code: "000000-not-the-code")
        _ = waitUntil(0.6) { false }
        check(pair.hostOutcome.value == nil && !FileManager.default.fileExists(atPath: pair.keyURL.path), "a Yes for some other code does nothing")
        pair.host.confirm(true, code: pair.hostCode.value ?? "")
        check(waitUntil(5) { pair.hostOutcome.value == .paired }, "a Yes for the code that was shown works")
        pair.host.stop()
    } else { check(false, "the host starts") }
    if let (pair, _) = makePair() {
        let resets = Box<Int>(); resets.value = 0
        pair.host.onReset = { resets.value = (resets.value ?? 0) + 1 }
        pair.guest.start()
        _ = waitUntil(5) { pair.hostCode.value != nil }
        pair.guest.cancel()
        check(waitUntil(3) { (resets.value ?? 0) >= 1 }, "the MacBook screen is told when the iMac goes away mid-pairing")
        pair.host.stop()
    } else { check(false, "the host starts") }

    // Finding 6: an existing key on the iMac is kept as a backup
    if let (pair, _) = makePair() {
        let old = Data((0..<32).map { UInt8($0) })
        try? PairingKey.store(old, at: pair.keyURL)
        pair.guest.start()
        _ = waitUntil(5) { pair.hostCode.value != nil }
        pair.host.confirm(true, code: pair.hostCode.value ?? "")
        _ = waitUntil(1) { false }
        pair.guest.confirm(true)
        check(waitUntil(5) { pair.guestOutcome.value == .paired }, "pairing over an existing key works")
        let backup = pair.keyURL.appendingPathExtension("previous")
        check(PairingKey.load(from: backup) == old, "the old key is kept as a backup")
        check(PairingKey.load(from: pair.keyURL) == pairingKey, "the new key replaces it")
        pair.host.stop()
    } else { check(false, "the host starts") }

    // N1 of the second review: a connection that says nothing must not hold the only slot until the window ends
    do {
        let p = nextPort()
        let host = PairingHost(pairingKey: pairingKey, port: p, window: 20, maxFailures: 5, sessionTimeout: 0.6, advertise: false, callbackQueue: queue)
        let resets = Box<Int>(); resets.value = 0
        host.onReset = { resets.value = (resets.value ?? 0) + 1 }
        try? host.start()
        let silent = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: p)!, using: .tcp)
        silent.start(queue: queue)
        check(waitUntil(3) { (resets.value ?? 0) >= 1 }, "a connection that stays silent is dropped after the session timeout")
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let guest = PairingGuest(host: "127.0.0.1", port: p, keyURL: dir.appendingPathComponent("k"), timeout: 5, callbackQueue: queue)
        let code = Box<String>()
        guest.onCode = { code.value = $0 }
        guest.start()
        check(waitUntil(4) { code.value != nil }, "a real iMac can pair once the silent connection is gone")
        silent.cancel(); guest.cancel(); host.stop()
    }

    // N3 of the second review: the iMac closing right after the key is sent is not a failed pairing
    do {
        var finishedPaired = 0
        for _ in 0..<5 {
            let p = nextPort()
            let host = PairingHost(pairingKey: pairingKey, port: p, window: 20, maxFailures: 1, advertise: false, callbackQueue: queue)
            let hostCode = Box<String>(), outcome = Box<PairingOutcome>()
            host.onCode = { hostCode.value = $0 }
            host.onFinished = { outcome.value = $0 }
            try? host.start()
            var initiator = PairingInitiator()
            let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: p)!, using: .tcp)
            conn.start(queue: queue)
            conn.send(content: frameMessage(.pairCommit, initiator.commitMessage()), completion: .idempotent)
            receiveMessages(on: conn, maxMessage: 128, onMessage: { type, payload in
                switch MessageType(rawValue: type) {
                case .pairResponse:
                    if let step = try? initiator.receiveResponse(payload) { conn.send(content: frameMessage(.pairReveal, step.reveal), completion: .idempotent) }
                case .pairSealed: conn.cancel()      // gone the moment the key arrives
                default: break
                }
            }, onClose: { _ in })
            if waitUntil(4, { hostCode.value != nil }) {
                host.confirm(true, code: hostCode.value ?? "")
                _ = waitUntil(3) { outcome.value != nil }
            }
            if outcome.value == .paired { finishedPaired += 1 }
            host.stop(); conn.cancel()
        }
        check(finishedPaired == 5, "the MacBook still reports paired when the iMac hangs up right after the key (5 of 5)")
    }

    // Nothing there to connect to
    do {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let guest = PairingGuest(host: "127.0.0.1", port: nextPort(), keyURL: dir.appendingPathComponent("k"), timeout: 5, callbackQueue: queue)
        let outcome = Box<PairingOutcome>()
        guest.onFinished = { outcome.value = $0 }
        guest.start()
        check(waitUntil(6) { if case .failed = outcome.value { return true } else { return false } }, "a guest with no host reports a failure")
    }
}
