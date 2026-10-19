// Tests for the shared protocol, key file, input and bitrate code.

import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runSharedTests() {
    // Hello round trip
    let hello = Hello(version: protocolVersion, pixelWidth: 4480, pixelHeight: 2520, scale: 2, refreshRate: 60)
    let decoded = try! Hello.decode(hello.encode())
    check(decoded.pixelWidth == 4480 && decoded.pixelHeight == 2520 && decoded.scale == 2 && decoded.refreshRate == 60, "hello round trip")
    check(hello.encode().count == 21, "a hello with no version is 21 bytes: 20 fixed and one length byte")

    // Pairing key file
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tbdisplay-test-\(UUID().uuidString)")
    let keyFile = dir.appendingPathComponent("pairing-key")
    let key1 = try! PairingKey.create(at: keyFile)
    check(key1.count == 32, "new key is 32 bytes")
    let mode = (try! FileManager.default.attributesOfItem(atPath: keyFile.path))[.posixPermissions] as! Int
    check(mode == 0o600, "key file is owner-only (0600)")
    let folderMode = (try! FileManager.default.attributesOfItem(atPath: dir.path))[.posixPermissions] as! Int
    check(folderMode & 0o077 == 0, "key folder is owner-only")
    check(PairingKey.load(from: keyFile) == key1, "key reads back")
    let key2 = try! PairingKey.create(at: keyFile)
    check(key2 != key1 && PairingKey.load(from: keyFile) == key2, "a new key replaces the old one")
    try! FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyFile.path)
    _ = PairingKey.load(from: keyFile)
    check(((try! FileManager.default.attributesOfItem(atPath: keyFile.path))[.posixPermissions] as! Int) == 0o600, "a loose key file is tightened on load")
    try! "not a key".write(to: keyFile, atomically: true, encoding: .utf8)
    check(PairingKey.load(from: keyFile) == nil, "garbage in the key file is refused")
    try! String(repeating: "ab", count: 16).write(to: keyFile, atomically: true, encoding: .utf8)
    check(PairingKey.load(from: keyFile) == nil, "a short key is refused")
    check(PairingKey.load(from: dir.appendingPathComponent("missing.key")) == nil, "a missing key file gives nil")
    check(Set((0..<20).map { _ in (try! PairingKey.create(at: keyFile)).hexString }).count == 20, "twenty new keys are all different")
    // A key file that exists but is unusable is never replaced
    let badFile = dir.appendingPathComponent("bad.key")
    try! "this is not a key".write(to: badFile, atomically: true, encoding: .utf8)
    var threw = false
    do { _ = try PairingKey.loadOrCreate(at: badFile) } catch { threw = true }
    check(threw && (try? String(contentsOf: badFile, encoding: .utf8)) == "this is not a key", "an unusable key file is reported, not overwritten")
    check(PairingKey.exists(at: badFile) && !PairingKey.exists(at: dir.appendingPathComponent("nothing.key")), "key file existence is reported")
    check(FailureTracker.key(for: "fe80:0:0:0:aaaa:bbbb:cccc:dddd") == FailureTracker.key(for: "fe80:0:0:0:1:2:3:4"), "IPv6 addresses in one /64 count as one")
    check(FailureTracker.key(for: "192.0.2.40") == "192.0.2.40", "IPv4 addresses are kept whole")
    try? FileManager.default.removeItem(at: dir)

    // Sanity checks the reviewer showed were needed
    check(Hello(version: 4, pixelWidth: 4480, pixelHeight: 2520, scale: 2, refreshRate: 60).isSane, "a normal screen size is accepted")
    check(!Hello(version: 4, pixelWidth: UInt32.max, pixelHeight: 2520, scale: 2, refreshRate: 60).isSane, "a huge width is refused")
    check(!Hello(version: 4, pixelWidth: 0, pixelHeight: 0, scale: 0, refreshRate: 0).isSane, "a zero size is refused")
    check(!Hello(version: 4, pixelWidth: 4480, pixelHeight: 2520, scale: 9, refreshRate: 60).isSane, "a scale of 9 is refused")
    check(InputEvent(kind: .mouseMove, dx: 1000, dy: -1000).isSane, "normal mouse movement is accepted")
    check(!InputEvent(kind: .mouseMove, dx: Int32.min).isSane, "the most negative movement is refused without crashing")
    check(!InputEvent(kind: .scroll, scrollY: Int32.min).isSane && !InputEvent(kind: .scroll, scrollX: Int32.max).isSane, "extreme scroll values are refused")
    check(!InputEvent(kind: .keyDown, keyCode: 0x1000).isSane && !InputEvent(kind: .mouseDown, button: 7).isSane, "odd key codes and buttons are refused")

    // Input events
    let event = InputEvent(kind: .mouseMove, dx: -250_000, dy: 40_000, button: 1, scrollX: -300, scrollY: 1200, keyCode: 12, flags: 0x100000)
    check((try? InputEvent.decode(event.encode())) == event, "input event round trip with negative movement and scroll")

    // Message framing
    let framed = frameMessage(.heartbeat, Data())
    check(framed == Data([5, 0, 0, 0, 0]), "heartbeat is type 5 with no payload")

    // Bitrate controller (sentBps is the load actually carried in the window)
    var c = BitrateController(cap: 150_000_000)
    check(c.update(avgSendMs: 5, frames: 0, sentBps: 0) == nil, "idle window changes nothing")
    check(c.update(avgSendMs: 80, frames: 30, sentBps: 20_000_000) == 105_000_000, "slow sends cut the bitrate by 30 percent")
    for _ in 0..<20 { _ = c.update(avgSendMs: 80, frames: 30, sentBps: 5_000_000) }
    check(c.current == 8_000_000, "bitrate stops at the 8 Mbps floor")
    check(c.update(avgSendMs: 5, frames: 30, sentBps: 6_000_000) == nil && c.update(avgSendMs: 5, frames: 30, sentBps: 6_000_000) == nil, "two clean windows do not raise it yet")
    check(c.update(avgSendMs: 5, frames: 30, sentBps: 6_000_000) == 9_200_000, "the third clean window raises it by 15 percent")
    check(c.update(avgSendMs: 25, frames: 30, sentBps: 9_000_000) == nil, "a middling window holds the bitrate")
    var quiet = BitrateController(cap: 150_000_000)
    _ = quiet.update(avgSendMs: 80, frames: 30, sentBps: 20_000_000)   // now 105 Mbps
    for _ in 0..<10 { _ = quiet.update(avgSendMs: 1, frames: 30, sentBps: 2_000_000) }
    check(quiet.current == 105_000_000, "quiet windows with tiny frames do not raise the bitrate")
    for _ in 0..<3 { _ = quiet.update(avgSendMs: 3, frames: 30, sentBps: 80_000_000) }
    check(quiet.current > 120_000_000 && quiet.current < 121_000_000, "three windows carrying real load raise it by about 15 percent")
    var steady = BitrateController(cap: 150_000_000)
    for _ in 0..<10 { _ = steady.update(avgSendMs: 3, frames: 30, sentBps: 140_000_000) }
    check(steady.current == 150_000_000, "a fast link under load stays at the cap")
}
