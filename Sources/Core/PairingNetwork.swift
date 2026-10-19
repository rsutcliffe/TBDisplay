// Pairing over the network: the host runs on the MacBook, the guest on the iMac.
// The host listens only while a pairing window is open. It serves one guest at a time, shows the code once the
// guest has revealed, and sends the pairing key only after the person says the codes match.

import Foundation
import Network

let pairPort: UInt16 = 47802
let pairServiceType = "_tbdisplay-pair._tcp"

enum PairingOutcome: Equatable {
    case paired, rejected, expired, tooManyFailures, cancelled
    case failed(String)
}

final class PairingHost {
    var onCode: ((String) -> Void)?
    var onFinished: ((PairingOutcome) -> Void)?

    private let pairingKey: Data
    private let port: UInt16
    private let window: TimeInterval
    private let maxFailures: Int
    private let sessionTimeout: TimeInterval
    private let advertise: Bool
    private let callbackQueue: DispatchQueue
    private let queue = DispatchQueue(label: "tbdisplay.pairing.host")

    private var listener: NWListener?
    private var active: NWConnection?
    private var responder: PairingResponder?
    private var awaitingConfirm = false
    private var currentCode: String?
    private var failures = 0
    private var decided = false          // the person has answered: a close after this is not a failed session
    private var finished = false

    init(pairingKey: Data, port: UInt16 = pairPort, window: TimeInterval = 120, maxFailures: Int = 3,
         sessionTimeout: TimeInterval = 15, advertise: Bool = true, callbackQueue: DispatchQueue = .main) {
        self.pairingKey = pairingKey
        self.port = port
        self.window = window
        self.maxFailures = maxFailures
        self.sessionTimeout = sessionTimeout
        self.advertise = advertise
        self.callbackQueue = callbackQueue
    }

    func start() throws {
        guard let number = NWEndpoint.Port(rawValue: port) else { throw ProtocolError.badVersion }
        let listener = try NWListener(using: .tcp, on: number)
        if advertise { listener.service = NWListener.Service(name: Host.current().localizedName ?? "MacBook", type: pairServiceType) }
        listener.newConnectionHandler = { [weak self] connection in self?.queue.async { self?.accept(connection) } }
        listener.start(queue: queue)
        self.listener = listener
        queue.asyncAfter(deadline: .now() + window) { [weak self] in self?.finish(.expired) }
    }

    /// Called when the guest in front of the person goes away without finishing, so the screen can drop its code.
    var onReset: (() -> Void)?

    /// The person's answer to "do both screens show the same code?". It belongs to the code that was on screen:
    /// an answer for any other code is ignored, so a new session cannot inherit a Yes meant for an old one.
    func confirm(_ yes: Bool, code: String) {
        queue.async { [weak self] in
            guard let self, self.awaitingConfirm, code == self.currentCode, let connection = self.active, let responder = self.responder else { return }
            self.awaitingConfirm = false
            self.decided = true
            if yes, let sealed = try? responder.sealedKey() {
                connection.send(content: frameMessage(.pairSealed, sealed), completion: .contentProcessed { _ in
                    self.queue.async { self.finish(.paired) }
                })
            } else {
                connection.send(content: frameMessage(.pairReject, Data()), completion: .contentProcessed { _ in
                    self.queue.async { self.finish(.rejected) }
                })
            }
        }
    }

    func stop() { queue.async { [weak self] in self?.finish(.cancelled) } }

    // MARK: On the queue

    private func accept(_ connection: NWConnection) {
        guard !finished, active == nil else { connection.cancel(); return }    // one guest at a time
        log("Pairing: a Mac connected from \(connection.endpoint)")
        active = connection
        responder = PairingResponder(pairingKey: pairingKey)
        decided = false
        // A guest that never reveals a code must not hold the only slot until the window ends.
        queue.asyncAfter(deadline: .now() + sessionTimeout) { [weak self] in
            guard let self, connection === self.active, !self.awaitingConfirm, !self.decided, !self.finished else { return }
            log("Pairing: a Mac was silent for too long. Dropping it.")
            self.failure(connection)
        }
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.queue.async { self?.closed(connection) } }
        }
        connection.start(queue: queue)
        receiveMessages(on: connection, maxMessage: 256,
                        onMessage: { [weak self] type, payload in self?.handle(type, payload, on: connection) },
                        onClose: { [weak self] _ in self?.closed(connection) })
    }

    private func handle(_ rawType: UInt8, _ payload: Data, on connection: NWConnection) {
        guard connection === active, !finished else { return }
        do {
            switch MessageType(rawValue: rawType) {
            case .pairCommit:
                let reply = try responder?.receiveCommit(payload) ?? { throw PairingError.outOfOrder }()
                connection.send(content: frameMessage(.pairResponse, reply), completion: .idempotent)
            case .pairReveal:
                let code = try responder?.receiveReveal(payload) ?? { throw PairingError.outOfOrder }()
                awaitingConfirm = true
                currentCode = code
                log("Pairing: a code is on screen. Waiting for the person to confirm.")
                callbackQueue.async { self.onCode?(code) }
            default:
                throw PairingError.outOfOrder
            }
        } catch {
            log("Pairing: a bad message from \(connection.endpoint) (\(error)).")
            failure(connection)
        }
    }

    /// A bad message. The connection is dropped and counted, and too many failures close the window.
    private func failure(_ connection: NWConnection) {
        connection.cancel()
        endSession()
    }

    /// A guest that goes away before the pairing is decided counts as a failure, just like a bad message.
    /// Otherwise someone could start sessions and walk away from the unlucky ones for free, which would let
    /// them try for a matching six digit code a million times, instead of three.
    private func closed(_ connection: NWConnection) {
        guard connection === active, !finished, !decided else { return }
        endSession()
    }

    private func endSession() {
        failures += 1
        active = nil
        responder = nil
        awaitingConfirm = false
        currentCode = nil
        callbackQueue.async { self.onReset?() }
        if failures >= maxFailures { finish(.tooManyFailures) }
    }

    private func finish(_ outcome: PairingOutcome) {
        guard !finished else { return }
        finished = true
        log("Pairing finished: \(outcome)")
        awaitingConfirm = false
        listener?.cancel(); listener = nil
        active?.cancel(); active = nil
        callbackQueue.async { self.onFinished?(outcome) }
    }
}

final class PairingGuest {
    var onCode: ((String) -> Void)?
    var onFinished: ((PairingOutcome) -> Void)?

    private let endpoint: NWEndpoint?
    private let keyURL: URL
    private let timeout: TimeInterval
    private let callbackQueue: DispatchQueue
    private let queue = DispatchQueue(label: "tbdisplay.pairing.guest")

    private var connection: NWConnection?
    private var initiator = PairingInitiator()
    private var finished = false
    private var localAnswer: Bool?        // what the person at this Mac said about the code
    private var pendingKey: Data?         // the key, held in memory until that person agrees

    init(endpoint: NWEndpoint, keyURL: URL = PairingKey.defaultURL, timeout: TimeInterval = 150,
         callbackQueue: DispatchQueue = .main) {
        self.endpoint = endpoint
        self.keyURL = keyURL
        self.timeout = timeout
        self.callbackQueue = callbackQueue
    }

    convenience init(host: String, port: UInt16 = pairPort, keyURL: URL = PairingKey.defaultURL, timeout: TimeInterval = 150,
                     callbackQueue: DispatchQueue = .main) {
        self.init(endpoint: NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 47802),
                  keyURL: keyURL, timeout: timeout, callbackQueue: callbackQueue)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, let endpoint = self.endpoint else { return }
            let connection = NWConnection(to: endpoint, using: .tcp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    connection.send(content: frameMessage(.pairCommit, self.initiator.commitMessage()), completion: .idempotent)
                case .failed(let error), .waiting(let error):
                    self.queue.async { self.finish(.failed("Could not reach the MacBook: \(error)")) }
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
            receiveMessages(on: connection, maxMessage: 128,
                            onMessage: { [weak self] type, payload in self?.handle(type, payload) },
                            onClose: { [weak self] _ in
                                // Once the key has arrived, the MacBook closing is normal: wait for this person's answer.
                                self?.queue.async { if self?.pendingKey == nil { self?.finish(.failed("The MacBook closed the connection.")) } }
                            })
            self.queue.asyncAfter(deadline: .now() + self.timeout) { [weak self] in self?.finish(.failed("Pairing timed out.")) }
        }
    }

    func cancel() { queue.async { [weak self] in self?.finish(.cancelled) } }

    /// The person at this Mac says whether its code matches the MacBook's. The key is stored only on a yes,
    /// so a computer posing as the MacBook cannot plant a key by itself.
    func confirm(_ yes: Bool) {
        queue.async { [weak self] in
            guard let self, !self.finished else { return }
            self.localAnswer = yes
            if yes { self.storeIfReady() } else { self.finish(.rejected) }
        }
    }

    private func storeIfReady() {
        guard !finished, localAnswer == true, let key = pendingKey else { return }
        do {
            // Pairing replaces the key, so the old one is kept beside it in case this was a mistake.
            if let old = PairingKey.load(from: keyURL), old != key {
                try PairingKey.store(old, at: keyURL.appendingPathExtension("previous"))
            }
            try PairingKey.store(key, at: keyURL)
            finish(.paired)
        }
        catch { finish(.failed("Could not save the key: \(error)")) }
    }

    private func handle(_ rawType: UInt8, _ payload: Data) {
        guard !finished else { return }
        do {
            switch MessageType(rawValue: rawType) {
            case .pairResponse:
                let step = try initiator.receiveResponse(payload)
                connection?.send(content: frameMessage(.pairReveal, step.reveal), completion: .idempotent)
                callbackQueue.async { self.onCode?(step.code) }
            case .pairSealed:
                pendingKey = try initiator.openKey(payload)
                storeIfReady()
            case .pairReject:
                finish(.rejected)
            default:
                finish(.failed("The MacBook sent something unexpected."))
            }
        } catch {
            finish(.failed("Pairing failed: \(error)"))
        }
    }

    private func finish(_ outcome: PairingOutcome) {
        guard !finished else { return }
        finished = true
        connection?.cancel(); connection = nil
        callbackQueue.async { self.onFinished?(outcome) }
    }
}
