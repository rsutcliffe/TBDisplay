// Shared protocol, framing and helpers used by both the server and the client.
//
// Wire format: every message is
//   [1 byte type][4 bytes big-endian payload length][payload]
// over a single TCP connection with Nagle disabled.

import Foundation
import Network
import Security

// MARK: - Constants

let serviceType = "_tbdisplay._tcp"
let defaultPort: UInt16 = 47800
let protocolVersion: UInt32 = 5
let appVersion = "1.8.3"      // shown in the windows and menus, so mismatched copies are easy to spot
let maxMessageSize = 64 * 1024 * 1024
let defaultInterfaceName = "bridge0" // Thunderbolt Bridge on macOS

enum MessageType: UInt8 {
    case hello = 1           // client -> server: version, screen pixel size, scale, refresh rate
    case videoConfig = 2     // server -> client: frame size and HEVC parameter sets (VPS/SPS/PPS)
    case videoFrame = 3      // server -> client: one encoded frame (length-prefixed NAL units)
    case keyframeRequest = 4 // client -> server: please send a keyframe
    case heartbeat = 5       // server -> client: once a second, lets the client spot a dead link
    case input = 7           // client -> server: keyboard, mouse and scroll events (only with --input)
    case pairCommit = 8      // pairing, iMac -> MacBook
    case pairResponse = 9    // pairing, MacBook -> iMac
    case pairReveal = 10     // pairing, iMac -> MacBook
    case pairSealed = 11     // pairing, MacBook -> iMac: the pairing key, sealed
    case pairReject = 12     // pairing, MacBook -> iMac: the person said the codes did not match
    case notice = 13         // server -> client: a sentence for the person, sent before the server closes
    case ended = 14          // server -> client: the person chose Disconnect, so the client must not reconnect by itself
}

struct Hello {
    var version: UInt32
    var pixelWidth: UInt32
    var pixelHeight: UInt32
    var scale: UInt32
    var refreshRate: UInt32
    var appVersion = ""     // the app's own version text, for clear messages when the two Macs differ

    static let maxVersionBytes = 32

    func encode() -> Data {
        var w = ByteWriter()
        w.u32(version); w.u32(pixelWidth); w.u32(pixelHeight); w.u32(scale); w.u32(refreshRate)
        var text = Data()
        for character in appVersion {           // cut at a whole character, never in the middle of one
            let next = Data(String(character).utf8)
            if text.count + next.count > Hello.maxVersionBytes { break }
            text.append(next)
        }
        w.u8(UInt8(text.count)); w.bytes(text)
        return w.data
    }

    /// A hello from before the version existed has none of it, and still decodes.
    static func decode(_ data: Data) throws -> Hello {
        var r = ByteReader(data)
        var hello = Hello(version: try r.u32(), pixelWidth: try r.u32(), pixelHeight: try r.u32(),
                          scale: try r.u32(), refreshRate: try r.u32())
        if let length = try? r.u8() {
            guard Int(length) <= maxVersionBytes else { throw ProtocolError.tooLarge }
            hello.appVersion = String(decoding: try r.bytes(Int(length)), as: UTF8.self)
        }
        return hello
    }

    /// Screen sizes a real Mac could report. Anything else is refused before it reaches the encoder.
    var isSane: Bool {
        (640...8192).contains(pixelWidth) && (480...8192).contains(pixelHeight)
            && (1...3).contains(scale) && (1...240).contains(refreshRate)
    }
}

/// The shared secret between the MacBook and the iMac: 32 random bytes kept in a file only the user can read.
/// It is the pre-shared key of the TLS connection, so it never travels over the network.
enum PairingKey {
    static let size = 32

    /// Where the key lives. The environment variable is for tests, so they never touch the real key.
    static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["TBDISPLAY_KEY_FILE"] { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tbdisplay/pairing-key")
    }

    /// Reads the key. Returns nil if the file is missing or not exactly 64 hex characters.
    /// A file that other users could read is tightened to owner-only on the way.
    static func load(from url: URL = defaultURL) -> Data? {
        // Permissions first. A key other users could read is tightened, and refused if it cannot be.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let mode = attrs[.posixPermissions] as? Int, mode & 0o077 != 0 {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let after = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int ?? 0o777
            if after & 0o077 != 0 {
                log("The pairing key file can be read by other users and cannot be tightened. Refusing to use it: \(url.path)")
                return nil
            }
            log("The pairing key file was readable by other users. It is now owner-only. Consider creating a new key, since it may have been read.")
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count == size * 2, let key = Data(hex: hex) else { return nil }
        return key
    }

    static func exists(at url: URL = defaultURL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Writes a key to its file, owner-only from the start. Used for a fresh key and for one that arrived by pairing.
    static func store(_ key: Data, at url: URL = defaultURL) throws {
        guard key.count == size else { throw ProtocolError.badKeyFile }
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temp = folder.appendingPathComponent(".pairing-key.\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: Data(key.hexString.utf8),
                                             attributes: [.posixPermissions: 0o600]) else { throw ProtocolError.truncated }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    /// Makes a new random key and replaces any old one.
    @discardableResult
    static func create(at url: URL = defaultURL) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: size)
        guard SecRandomCopyBytes(kSecRandomDefault, size, &bytes) == errSecSuccess else { throw ProtocolError.truncated }
        let key = Data(bytes)
        try store(key, at: url)
        return key
    }

    /// Creates a key only when there is no file. A file that exists but cannot be used is an error,
    /// never silently replaced, because replacing it would lock out every paired Mac.
    static func loadOrCreate(at url: URL = defaultURL) throws -> Data {
        if let key = load(from: url) { return key }
        if exists(at: url) { throw ProtocolError.badKeyFile }
        return try create(at: url)
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(); var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte); index = next
        }
        self = data
    }
}

/// One keyboard, mouse or scroll event sent from the iMac to the MacBook.
/// Pointer movement is relative, as a fraction of the iMac screen, so the pointer can run off
/// the iMac display onto the MacBook screens. Clicks and scrolls happen where the pointer is.
struct InputEvent: Equatable {
    enum Kind: UInt8 { case mouseMove = 1, mouseDown = 2, mouseUp = 3, scroll = 4, keyDown = 5, keyUp = 6 }
    var kind: Kind
    var dx: Int32 = 0          // mouse movement across, in millionths of the screen width
    var dy: Int32 = 0          // mouse movement down, in millionths of the screen height
    var button: UInt8 = 0      // 0 left, 1 right, 2 other
    var scrollX: Int32 = 0     // in hundredths of a pixel
    var scrollY: Int32 = 0
    var keyCode: UInt32 = 0
    var flags: UInt32 = 0      // modifier flags, as in NSEvent.modifierFlags.rawValue

    /// Values no real keyboard or mouse would send. Written as ranges, because abs() traps on the most negative number.
    var isSane: Bool {
        (-2_000_000...2_000_000).contains(dx) && (-2_000_000...2_000_000).contains(dy)
            && (-1_000_000...1_000_000).contains(scrollX) && (-1_000_000...1_000_000).contains(scrollY)
            && button <= 2 && keyCode <= 0xFF
    }

    func encode() -> Data {
        var w = ByteWriter()
        w.u8(kind.rawValue); w.u32(UInt32(bitPattern: dx)); w.u32(UInt32(bitPattern: dy)); w.u8(button)
        w.u32(UInt32(bitPattern: scrollX)); w.u32(UInt32(bitPattern: scrollY))
        w.u32(keyCode); w.u32(flags)
        return w.data
    }

    static func decode(_ data: Data) throws -> InputEvent {
        var r = ByteReader(data)
        guard let kind = Kind(rawValue: try r.u8()) else { throw ProtocolError.truncated }
        return InputEvent(kind: kind, dx: Int32(bitPattern: try r.u32()), dy: Int32(bitPattern: try r.u32()), button: try r.u8(),
                          scrollX: Int32(bitPattern: try r.u32()), scrollY: Int32(bitPattern: try r.u32()),
                          keyCode: try r.u32(), flags: try r.u32())
    }
}

/// Picks the video bitrate from how long frames take to leave the socket.
/// Slow sends mean the link is the limit, so cut quickly. Raise slowly after steady clean seconds.
struct BitrateController {
    let cap: Int
    let floor = 8_000_000
    private(set) var current: Int
    private var cleanWindows = 0

    init(cap: Int) { self.cap = cap; self.current = cap }

    /// Feed one window of results. `sentBps` is the bits per second actually sent in the window.
    /// Returns a new bitrate when it should change, otherwise nil.
    mutating func update(avgSendMs: Double, frames: Int, sentBps: Double) -> Int? {
        guard frames > 0 else { return nil }            // idle screen, nothing learned
        if avgSendMs > 40 {
            cleanWindows = 0
            let next = max(floor, Int(Double(current) * 0.7))
            guard next != current else { return nil }
            current = next
            return next
        }
        // Small frames always send fast, so only a window that carried at least half the current
        // bitrate proves the link copes. Quieter windows say nothing and leave the counter alone.
        if avgSendMs < 15 && sentBps >= Double(current) * 0.5 {
            cleanWindows += 1
            if cleanWindows >= 3, current < cap {
                cleanWindows = 0
                current = min(cap, Int(Double(current) * 1.15))
                return current
            }
        } else if avgSendMs >= 15 {
            cleanWindows = 0
        }
        return nil
    }
}

struct VideoConfig {
    var width: UInt32
    var height: UInt32
    var nalUnitHeaderLength: UInt8
    var parameterSets: [Data]

    func encode() -> Data {
        var w = ByteWriter()
        w.u32(width); w.u32(height); w.u8(nalUnitHeaderLength); w.u8(UInt8(parameterSets.count))
        for set in parameterSets { w.u32(UInt32(set.count)); w.bytes(set) }
        return w.data
    }

    static func decode(_ data: Data) throws -> VideoConfig {
        var r = ByteReader(data)
        let width = try r.u32(), height = try r.u32()
        let nal = try r.u8(), count = Int(try r.u8())
        var sets: [Data] = []
        for _ in 0..<count { let len = Int(try r.u32()); sets.append(try r.bytes(len)) }
        return VideoConfig(width: width, height: height, nalUnitHeaderLength: nal, parameterSets: sets)
    }
}

struct VideoFrameHeader {
    static let size = 9
    var isKeyframe: Bool
    var ptsMicros: Int64

    func encode() -> Data {
        var w = ByteWriter()
        w.u8(isKeyframe ? 1 : 0); w.i64(ptsMicros)
        return w.data
    }
}

// MARK: - Byte helpers

enum ProtocolError: Error { case truncated, tooLarge, badVersion, badKeyFile }

struct ByteWriter {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func i64(_ v: Int64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func bytes(_ d: Data) { data.append(d) }
}

struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) { self.data = data; self.offset = data.startIndex }

    var remaining: Data { data[offset..<data.endIndex] }

    mutating func u8() throws -> UInt8 {
        guard offset < data.endIndex else { throw ProtocolError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func u32() throws -> UInt32 {
        var v: UInt32 = 0
        for _ in 0..<4 { v = (v << 8) | UInt32(try u8()) }
        return v
    }

    mutating func i64() throws -> Int64 {
        var v: UInt64 = 0
        for _ in 0..<8 { v = (v << 8) | UInt64(try u8()) }
        return Int64(bitPattern: v)
    }

    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, offset + n <= data.endIndex else { throw ProtocolError.truncated }
        defer { offset += n }
        return Data(data[offset..<(offset + n)])
    }
}

func frameMessage(_ type: MessageType, _ payload: Data) -> Data {
    var w = ByteWriter()
    w.u8(type.rawValue)
    w.u32(UInt32(payload.count))
    w.bytes(payload)
    return w.data
}

// MARK: - Networking

/// TCP with TLS 1.2 and the pairing key as a pre-shared key. Both ends must hold the same key or the
/// handshake fails. The suite is ECDHE-PSK with ChaCha20-Poly1305, so a key stolen later cannot decrypt
/// traffic recorded earlier. (Checked on this macOS: it negotiates, and a wrong key fails with "bad MAC".)
func makeTCPParameters(key: Data) -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 2
    tcp.keepaliveInterval = 1
    tcp.keepaliveCount = 3
    tcp.connectionTimeout = 5

    let tls = NWProtocolTLS.Options()
    let sec = tls.securityProtocolOptions
    let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
    let identity = Data("tbdisplay-v4".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
    sec_protocol_options_add_pre_shared_key(sec, psk as __DispatchData, identity as __DispatchData)
    sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: 0xCCAC)!)   // TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256
    sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)

    let params = NWParameters(tls: tls, tcp: tcp)
    params.serviceClass = .interactiveVideo
    params.includePeerToPeer = false
    return params
}

/// True only when the connection really negotiated the one suite we allow. Anything else is closed.
func negotiatedAsExpected(_ conn: NWConnection) -> Bool {
    guard let meta = conn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return false }
    let sec = meta.securityProtocolMetadata
    let suite = UInt16(bitPattern: Int16(truncatingIfNeeded: sec_protocol_metadata_get_negotiated_tls_ciphersuite(sec).rawValue))
    return suite == 0xCCAC && sec_protocol_metadata_get_negotiated_tls_protocol_version(sec) == .TLSv12
}

/// Short description of the encryption in use, for the log.
func encryptionSummary(of conn: NWConnection) -> String {
    guard let meta = conn.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return "not encrypted" }
    let raw = UInt16(bitPattern: Int16(truncatingIfNeeded: sec_protocol_metadata_get_negotiated_tls_ciphersuite(meta.securityProtocolMetadata).rawValue))
    return raw == 0xCCAC ? "TLS 1.2 ECDHE-PSK ChaCha20-Poly1305" : String(format: "TLS suite 0x%04X", raw)
}

/// Reads framed messages from a connection until it closes or fails.
/// `onMessage` and `onClose` run on the connection's queue.
func receiveMessages(on conn: NWConnection,
                     maxMessage: Int = maxMessageSize,
                     onMessage: @escaping (UInt8, Data) -> Void,
                     onClose: @escaping (Error?) -> Void) {
    conn.receive(minimumIncompleteLength: 5, maximumLength: 5) { header, _, isComplete, error in
        if let error { onClose(error); return }
        guard let header, header.count == 5 else { onClose(nil); return }
        var r = ByteReader(header)
        guard let type = try? r.u8(), let length = try? r.u32() else { onClose(ProtocolError.truncated); return }
        guard Int(length) <= maxMessage else { onClose(ProtocolError.tooLarge); return }
        if length == 0 {
            onMessage(type, Data())
            if isComplete { onClose(nil) } else { receiveMessages(on: conn, maxMessage: maxMessage, onMessage: onMessage, onClose: onClose) }
            return
        }
        conn.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { body, _, _, error in
            if let error { onClose(error); return }
            guard let body, body.count == Int(length) else { onClose(nil); return }
            onMessage(type, body)
            receiveMessages(on: conn, maxMessage: maxMessage, onMessage: onMessage, onClose: onClose)
        }
    }
}

/// Name of the interface an established connection is using, for logging and access checks.
func interfaceName(of conn: NWConnection) -> String? {
    conn.currentPath?.availableInterfaces.first?.name
}

/// Looks up a live network interface object by BSD name (for example "bridge0").
func findInterface(named name: String, timeout: TimeInterval = 1.0) -> NWInterface? {
    let monitor = NWPathMonitor()
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var found: NWInterface?
    monitor.pathUpdateHandler = { path in
        lock.lock(); found = path.availableInterfaces.first { $0.name == name }; lock.unlock()
        done.signal()
    }
    monitor.start(queue: DispatchQueue(label: "tbdisplay.pathmonitor"))
    _ = done.wait(timeout: .now() + timeout)
    monitor.cancel()
    lock.lock(); defer { lock.unlock() }
    return found
}

// MARK: - Preferences

/// The few things remembered between runs. The environment variable lets tests use a throwaway store.
enum Prefs {
    static var defaults: UserDefaults {
        ProcessInfo.processInfo.environment["TBDISPLAY_PREFS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }
    static let firstRunDone = "tbdisplay.firstRunDone"
    static let everConnected = "tbdisplay.everConnected"     // an iMac has connected to this MacBook
    static let updateCheckDisabled = "tbdisplay.updateCheckDisabled"   // the person turned automatic update checks off
    static let lastUpdateCheck = "tbdisplay.lastUpdateCheck"           // when the last successful check finished
}

// MARK: - Logging and arguments

private let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

/// A log file with one older copy kept. Apps opened from Applications have nowhere for stderr to go, so this is how
/// their log is read afterwards. A failure to write is ignored: logging must never stop the app.
final class LogFile {
    static var shared: LogFile?

    let url: URL
    private let maxBytes: Int
    private let lock = NSLock()

    init(url: URL, maxBytes: Int = 1_000_000) {
        self.url = url
        self.maxBytes = maxBytes
    }

    /// ~/Library/Logs/TBDisplay/<name>.log, or the same name inside the folder given by TBDISPLAY_LOG_DIR (used by the tests).
    static func defaultURL(name: String) -> URL {
        let folder: URL
        if let dir = ProcessInfo.processInfo.environment["TBDISPLAY_LOG_DIR"] {
            folder = URL(fileURLWithPath: dir)
        } else {
            folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TBDisplay")
        }
        return folder.appendingPathComponent("\(name).log")
    }

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        let files = FileManager.default
        let data = Data(line.utf8)
        try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let size = (try? files.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
        if size > 0 && size + data.count > maxBytes {
            let older = url.appendingPathExtension("1")
            try? files.removeItem(at: older)
            try? files.moveItem(at: url, to: older)
        }
        if !files.fileExists(atPath: url.path) {
            files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

func log(_ message: String) {
    let line = "[\(logFormatter.string(from: Date()))] \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
    LogFile.shared?.append(line)
}

struct Arguments {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ argv: [String] = CommandLine.arguments, flagNames: Set<String>) {
        var i = 1
        while i < argv.count {
            let arg = argv[i]
            if arg.hasPrefix("--") {
                let key = String(arg.dropFirst(2))
                if flagNames.contains(key) {
                    flags.insert(key)
                } else if i + 1 < argv.count {
                    values[key] = argv[i + 1]
                    i += 1
                } else {
                    log("Missing value for \(arg)")
                }
            }
            i += 1
        }
    }

    func string(_ key: String) -> String? { values[key] }
    func int(_ key: String) -> Int? { values[key].flatMap { Int($0) } }
    func flag(_ key: String) -> Bool { flags.contains(key) }
}
