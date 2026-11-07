// A real attempt to reach the MacBook, the way the client does it, for the Connection check window and `--check`.
// It never sends a hello, so it cannot start a stream on the MacBook. What it learns becomes a ProbeOutcome, and
// ConnectionProbe turns that into plain sentences (Sources/Core/ConnectionProbe.swift).

import Foundation
import Network

enum MacBookProbe {
    static let browseSeconds = 6.0
    static let connectSeconds = 8.0
    static let listenSeconds = 1.5

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        private var _endpoint: NWEndpoint?
        private var _interface: NWInterface?
        private var _seen = Set<String>()
        private var _ready = false
        private var _failure: NWError?
        private var _notice: String?
        func choose(_ endpoint: NWEndpoint, _ interface: NWInterface) { lock.lock(); if _endpoint == nil { _endpoint = endpoint; _interface = interface }; lock.unlock() }
        func see(_ names: [String]) { lock.lock(); _seen.formUnion(names); lock.unlock() }
        func markReady() { lock.lock(); _ready = true; lock.unlock() }
        func fail(_ error: NWError) { lock.lock(); _failure = error; lock.unlock() }
        func setNotice(_ text: String) { lock.lock(); _notice = text; lock.unlock() }
        var chosen: (NWEndpoint, NWInterface)? { lock.lock(); defer { lock.unlock() }; if let e = _endpoint, let i = _interface { return (e, i) }; return nil }
        var seen: [String] { lock.lock(); defer { lock.unlock() }; return _seen.sorted() }
        var ready: Bool { lock.lock(); defer { lock.unlock() }; return _ready }
        var failure: NWError? { lock.lock(); defer { lock.unlock() }; return _failure }
        var notice: String? { lock.lock(); defer { lock.unlock() }; return _notice }
    }

    /// The name a person knows a connection by.
    private static func label(_ name: String, _ kind: InterfaceKind) -> String {
        if name == defaultInterfaceName { return "Thunderbolt" }
        switch kind {
        case .wifi: return "Wi-Fi"
        case .wired: return "Ethernet"
        default: return name
        }
    }

    /// Blocks for up to about 16 seconds, so call it away from the main thread.
    static func run(policy: InterfacePolicy) -> (findings: [Finding], outcome: ProbeOutcome?) {
        var mode = ConnectionMode.thunderbolt
        if case .mode(let chosen) = policy { mode = chosen }
        guard let key = PairingKey.load() else {
            return ([Finding(level: .problem, title: "This iMac has no pairing key", detail: "Choose Pair with MacBook... to get one.")], nil)
        }
        let queue = DispatchQueue(label: "tbdisplay.probe")
        let box = Box()

        // 1. Look for the MacBook over the chosen connection
        let found = DispatchSemaphore(value: 0)
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: makeTCPParameters(key: key))
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                let interfaces = result.interfaces.map { (name: $0.name, kind: interfaceKind($0.type)) }
                box.see(interfaces.map { label($0.name, $0.kind) })
                if let index = InterfaceChoice.pick(interfaces, policy: policy) {
                    box.choose(result.endpoint, result.interfaces[index])
                    found.signal()
                }
            }
        }
        browser.start(queue: queue)
        _ = found.wait(timeout: .now() + browseSeconds)
        browser.cancel()
        guard let (endpoint, interface) = box.chosen else {
            let outcome: ProbeOutcome = box.seen.isEmpty ? .notSeen : .seenOnlyOther(box.seen)
            return (ConnectionProbe.findings(outcome, mode: mode), outcome)
        }

        // 2. Connect, and see whether the MacBook says anything
        let params = makeTCPParameters(key: key)
        params.requiredInterface = interface
        let connection = NWConnection(to: endpoint, using: params)
        let finished = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: box.markReady(); finished.signal()
            case .failed(let error): box.fail(error); finished.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        _ = finished.wait(timeout: .now() + connectSeconds)
        var outcome: ProbeOutcome
        if box.ready {
            receiveMessages(on: connection,
                            onMessage: { type, payload in
                                if MessageType(rawValue: type) == .notice { box.setNotice(String(decoding: payload.prefix(300), as: UTF8.self)) }
                            },
                            onClose: { _ in })
            Thread.sleep(forTimeInterval: listenSeconds)
            outcome = box.notice.map { .notice($0) } ?? .reachable
        } else if case .tls? = box.failure {
            outcome = .handshakeRefused
        } else {
            outcome = .noAnswer
        }
        connection.cancel()
        return (ConnectionProbe.findings(outcome, mode: mode), outcome)
    }
}
