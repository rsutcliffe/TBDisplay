// tbdisplay-server: run on the MacBook Pro.
// Waits for the iMac client over the Thunderbolt Bridge, then adds a virtual display
// sized to the iMac and streams it as low-latency HEVC, inside a TLS connection
// keyed by the pairing key.

import AppKit
import CoreGraphics
import Network

let usage = """
Usage: tbdisplay-server [options]
  --port N            TCP port (default \(defaultPort))
  --bitrate N         Video bitrate cap in Mbps (default 150). The bitrate falls on a slow link and recovers up to this
  --no-adapt          Keep the bitrate fixed
  --fps N             Frame rate cap (default 60)
  --max-in-flight N   Frames allowed in the encoder or socket at once (default 2)
  --interface NAME    Only accept clients on this interface (default: the Connect over choice in the menu bar item, Thunderbolt at first)
  --any-interface     Accept clients on any interface, including Wi-Fi (not recommended)
  --no-hidpi          Run the iMac at native pixels instead of Retina scaling
  --help              Show this help

Pairing: the first run creates a random pairing key (see the log for its place). Copy that file to the same
place on the iMac, by AirDrop. Keyboard and mouse from the iMac are switched on from the menu bar item.
"""

LogFile.shared = LogFile(url: LogFile.defaultURL(name: "server"))

if CommandLine.arguments.contains("--pin") || CommandLine.arguments.contains("--input") {
    log("--pin and --input were removed. Pairing uses a key file now, and keyboard and mouse are switched on from the menu bar item.")
    exit(1)
}

let args = Arguments(flagNames: ["any-interface", "no-hidpi", "no-adapt", "help"])
if args.flag("help") { print(usage); exit(0) }

var options = ServerOptions()
if let port = args.int("port") { options.port = UInt16(clamping: port) }
if let mbps = args.int("bitrate") { options.bitrate = max(5, mbps) * 1_000_000 }
if let fps = args.int("fps") { options.fps = min(max(fps, 10), 120) }
if let n = args.int("max-in-flight") { options.maxInFlight = min(max(n, 1), 8) }
if let name = args.string("interface") { options.policy = .named(name) }
if args.flag("any-interface") { options.policy = .any }
if args.flag("no-hidpi") { options.hiDPI = false }
if args.flag("no-adapt") { options.adaptBitrate = false }

final class Server {
    private var options: ServerOptions
    let state: ServerState
    private let tracker = FailureTracker()
    private var key: Data
    var pairingKey: Data { key }
    private var listener: NWListener?
    private var session: StreamSession?
    private var pendingLogged = false
    private(set) var gate = ConnectionGate()
    private var pending: [StreamSession] = []      // shaking hands, kept alive until they finish or fail
    private let queue = DispatchQueue(label: "tbdisplay.listener")

    init(options: ServerOptions, key: Data, state: ServerState) {
        self.options = options
        self.key = key
        self.state = state
    }

    private func host(of endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint { return "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)" }
        return "\(endpoint)"
    }

    func start() throws {
        guard let port = NWEndpoint.Port(rawValue: options.port) else { throw ProtocolError.badVersion }
        let listener = try NWListener(using: makeTCPParameters(key: key), on: port)
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "MacBook", type: serviceType)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                log("Listening on port \(self.options.port), accepting connections \(self.options.policy.summary). Start tbdisplay-client on the iMac.")
            case .failed(let error):
                log("Listener failed: \(error)")
                exit(1)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            DispatchQueue.main.async { [self] in
                let address = self.host(of: connection.endpoint)
                if self.tracker.isBlocked(address) {
                    connection.cancel()
                    return
                }
                // Cap the connections still shaking hands, so silent ones cannot use up the server.
                if self.pending.count >= 8 {
                    if !self.pendingLogged { self.pendingLogged = true; log("Too many unauthenticated connections. Refusing new ones until they finish.") }
                    connection.cancel()
                    return
                }
                self.pendingLogged = false
                var sessionOptions = self.options
                if !self.gate.accepts { sessionOptions.pausedNotice = ConnectionGate.pausedNotice }
                let session = StreamSession(connection: connection, options: sessionOptions, state: self.state)
                self.pending.append(session)
                session.onHandshakeFailed = { [weak self] in
                    guard let self else { return }
                    if self.tracker.recordFailure(address) {
                        log("Too many failed attempts from \(address). Refusing it for \(Int(self.tracker.lockout)) seconds.")
                    }
                }
                session.onAuthenticated = { [weak self, weak session] in
                    guard let self, let session else { return }
                    self.pending.removeAll { $0 === session }
                    self.tracker.recordSuccess(address)
                    Prefs.defaults.set(true, forKey: Prefs.everConnected)
                    // One iMac at a time. A client that has proved it holds the key replaces the old one.
                    if let old = self.session, old !== session {
                        log("New client replacing the existing session")
                        old.onClose = nil
                        old.stop()
                    }
                    self.session = session
                }
                session.onClose = { [weak self, weak session] in
                    guard let session else { return }
                    self?.pending.removeAll { $0 === session }
                    if self?.session === session { self?.session = nil }
                }
                session.start()
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// Starts listening again with a new key. Everyone paired with the old key is refused.
    func restart(key: Data) {
        shutdown()
        self.key = key
        try? start()
    }

    /// Drops the iMac and refuses it until `resume`, because the client would reconnect within a second.
    func disconnect() {
        gate.pause()
        pending.forEach { $0.stop() }
        pending = []
        session?.end()
        log("Disconnected from the menu. New connections are refused until you choose Allow connections.")
    }

    func resume() { gate.resume(); log("Connections allowed again.") }

    var policy: InterfacePolicy { options.policy }

    /// The person chose how the iMac reaches this Mac. It is saved, applies to the next connection, and the current
    /// one ends so the iMac meets the new rule (and is told what it is) instead of carrying on the old way.
    func setMode(_ mode: ConnectionMode) {
        mode.save()
        options.policy = .mode(mode)
        log("Connect over: \(mode.title). Connections are accepted \(options.policy.summary).")
        pending.forEach { $0.stop() }
        pending = []
        session?.end()
    }

    /// Stops everything. `then` runs once the virtual display has really been removed (or after 4 seconds),
    /// because exiting first can leave macOS holding the display for minutes.
    func shutdown(then: @escaping () -> Void = {}) {
        pending.forEach { $0.stop() }
        pending = []
        listener?.cancel()
        listener = nil
        guard let active = session else { then(); return }
        session = nil
        var finished = false
        let finish = { if !finished { finished = true; then() } }
        active.onClose = finish
        active.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: finish)
    }
}

// Screen Recording permission is required to capture the virtual display.
if !CGPreflightScreenCaptureAccess() {
    log("Screen Recording permission is needed. Approve the prompt, or add Terminal in System Settings > Privacy & Security > Screen & System Audio Recording, then restart Terminal.")
    CGRequestScreenCaptureAccess()
}

let keyAlreadyExisted = PairingKey.exists()
let pairingKey: Data
do {
    pairingKey = try PairingKey.loadOrCreate()
} catch {
    if keyAlreadyExisted {
        log("The pairing key file exists but is not a usable key: \(PairingKey.defaultURL.path). It is 64 hex characters on one line. Fix it, or delete it to make a new key (every paired Mac must then be given the new one). I will not replace it myself.")
    } else {
        log("Could not create the pairing key: \(error)")
    }
    exit(1)
}
log(keyAlreadyExisted ? "Pairing key: \(PairingKey.defaultURL.path)"
                      : "Created a new pairing key at \(PairingKey.defaultURL.path). Copy that file to the iMac by AirDrop, into the same folder.")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let serverState = ServerState()
let server = Server(options: options, key: pairingKey, state: serverState)
PowerLog.start()
let statusController = StatusController(state: serverState, server: server)
UpdateController.shared.checkAtLaunchIfDue()
DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { statusController.showChecklistIfNeeded() }   // once the app has finished starting
do {
    try server.start()
} catch {
    log("Could not start listener: \(error)")
    exit(1)
}

// Ctrl-C removes the virtual display cleanly before exiting.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        log("Stopping")
        server.shutdown { exit(0) }
    }
    source.resume()
    signalSources.append(source)
}

app.run()
