// What the iMac client window says and shows, decided from what has happened on the connection.
// No window code here, so it can be tested directly.

enum ClientEvent: Equatable {
    case keyMissing                  // no pairing key file on this Mac
    case keyFound
    case connecting                  // a new attempt starts
    case dataReceived                // the MacBook sent a heartbeat or video
    case pictureShown                // the first frame is on screen
    case lost                        // the link went quiet
    case refused(String?)            // the MacBook said no, with its own reason if it gave one
    case closed(hadData: Bool)       // the connection ended
    case stalled                     // nothing has come from the MacBook for a while
    case endedByMacBook              // the person chose Disconnect on the MacBook: do not retry
}

enum ClientPhase: Equatable {
    case needsKey, searching, connecting, refused, waitingForPicture, streaming, lost, ended
}

enum ClientPresentation: Equatable { case setupWindow, fullScreen }

struct ClientModel {
    private(set) var phase: ClientPhase = .searching
    private var reason: String?
    private var stalled = false      // a while has passed with nothing from the MacBook

    mutating func handle(_ event: ClientEvent) {
        // Once the MacBook has ended the connection, only a new attempt or a missing key changes anything.
        if phase == .ended {
            switch event {
            case .connecting, .keyMissing: break
            default: return
            }
        }
        switch event {
        case .keyMissing:
            phase = .needsKey
        case .keyFound:
            if phase == .needsKey { phase = .searching }
        case .connecting:
            phase = .connecting
            reason = nil
        case .dataReceived:
            stalled = false
            if phase != .streaming { phase = .waitingForPicture }
        case .pictureShown:
            stalled = false
            phase = .streaming
        case .lost:
            phase = .lost
        case .refused(let why):
            phase = .refused
            reason = why
        case .stalled:
            stalled = true
        case .endedByMacBook:
            phase = .ended
        case .closed(let hadData):
            if hadData { phase = .lost }
            else if phase != .refused { phase = .refused; reason = nil }     // a reason already given stays
        }
    }

    private static let cableAdvice = "Still nothing after a while. Check the cable is fully in at both ends and that TBDisplay is running on the MacBook. If the cable was unplugged and plugged back in, try restarting this iMac. Press Check connection to find out why."

    var statusMessage: String {
        let base = baseMessage
        // Advice about the cable only where the MacBook has not said anything of its own
        let wantsAdvice = stalled && (phase == .searching || phase == .connecting || phase == .lost || (phase == .refused && reason == nil))
        return wantsAdvice ? "\(base) \(Self.cableAdvice)" : base
    }

    private var baseMessage: String {
        switch phase {
        case .needsKey: return "No pairing key on this Mac. Pair with the MacBook to continue."
        case .searching: return "Looking for your MacBook…"
        case .connecting: return "Connecting…"
        case .refused:
            return "The MacBook refused the connection. \(reason ?? "Check the pairing key and the cable.") Retrying…"
        case .waitingForPicture: return "Connected. Waiting for the picture…"
        case .streaming: return ""
        case .lost: return "Connection lost. Reconnecting…"
        case .ended: return "The MacBook ended the connection. Choose Allow connections in its menu bar item. This iMac reconnects by itself within about 30 seconds, or press Reconnect now."
        }
    }

    var presentation: ClientPresentation { phase == .streaming ? .fullScreen : .setupWindow }

    /// The iMac is held awake only while a picture is streaming, so it sleeps by itself when nothing is shown.
    var keepsDisplayAwake: Bool { phase == .streaming }
}
