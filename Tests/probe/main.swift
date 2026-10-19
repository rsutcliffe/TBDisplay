// Test client: connects to a server with the pairing key, sends a few small mouse moves, and exits.
// Usage: probe PORT      (the key comes from TBDISPLAY_KEY_FILE, as for the real client)

import Foundation
import Network

guard let key = PairingKey.load(), let port = NWEndpoint.Port(rawValue: UInt16(CommandLine.arguments[1])!) else {
    print("FAIL no key"); exit(1)
}
let queue = DispatchQueue(label: "probe")
let conn = NWConnection(host: "127.0.0.1", port: port, using: makeTCPParameters(key: key))
let oldClient = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "oldhello"      // pretends to be an older app
let hello = Hello(version: oldClient ? 4 : protocolVersion, pixelWidth: 2560, pixelHeight: 1440, scale: 2, refreshRate: 60,
                  appVersion: oldClient ? "1.6.0" : appVersion)
var sent = false

func sendInput() {
    guard !sent else { return }
    sent = true
    for _ in 0..<5 {
        conn.send(content: frameMessage(.input, InputEvent(kind: .mouseMove, dx: 2000, dy: 0).encode()), completion: .idempotent)
    }
    queue.asyncAfter(deadline: .now() + 1.5) { print("SENT"); exit(0) }
}

conn.stateUpdateHandler = { state in
    switch state {
    case .ready:
        conn.send(content: frameMessage(.hello, hello.encode()), completion: .idempotent)
        receiveMessages(on: conn, onMessage: { type, payload in
            if MessageType(rawValue: type) == .notice { print("NOTICE: \(String(decoding: payload, as: UTF8.self))"); exit(0) }
            if MessageType(rawValue: type) == .heartbeat || MessageType(rawValue: type) == .videoFrame {
                queue.asyncAfter(deadline: .now() + 0.5) { sendInput() }
            }
        }, onClose: { _ in print("FAIL closed before input was sent"); exit(1) })
    case .failed(let e): print("FAIL \(e)"); exit(1)
    default: break
    }
}
conn.start(queue: queue)
queue.asyncAfter(deadline: .now() + 30) { print("FAIL timed out"); exit(1) }
dispatchMain()
