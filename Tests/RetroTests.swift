// Tests for code that existed before the project followed test-first. The first group was written AFTER the code,
// so it passed straight away and proves less: each of these was checked by breaking the code on purpose (see the
// notes in the project report). The second group drove small changes to the code and was written first.

import CoreGraphics
import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runRetroTests() {
    // MARK: written after the code

    // Byte reader and writer
    var w = ByteWriter()
    w.u8(7); w.u32(0xDEADBEEF); w.i64(-2); w.bytes(Data([1, 2, 3]))
    check(w.data == Data([7, 0xDE, 0xAD, 0xBE, 0xEF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE, 1, 2, 3]), "numbers are written big-endian")
    var r = ByteReader(w.data)
    check((try? r.u8()) == 7 && (try? r.u32()) == 0xDEADBEEF && (try? r.i64()) == -2 && (try? r.bytes(3)) == Data([1, 2, 3]), "the reader gives back what was written")
    check((try? r.u8()) == nil, "reading past the end throws instead of crashing")
    var short = ByteReader(Data([1, 2]))
    check((try? short.u32()) == nil, "a short number throws")
    var neg = ByteReader(Data([1, 2, 3]))
    check((try? neg.bytes(-1)) == nil && (try? neg.bytes(4)) == nil, "a negative or too long byte count throws")

    // Video config and frame header
    let config = VideoConfig(width: 4480, height: 2520, nalUnitHeaderLength: 4, parameterSets: [Data([1, 2]), Data([3, 4, 5])])
    let back = try? VideoConfig.decode(config.encode())
    check(back?.width == 4480 && back?.height == 2520 && back?.nalUnitHeaderLength == 4 && back?.parameterSets == [Data([1, 2]), Data([3, 4, 5])], "a video config survives a round trip")
    check((try? VideoConfig.decode(config.encode().dropLast(2))) == nil, "a cut-off video config is refused")
    let header = VideoFrameHeader(isKeyframe: true, ptsMicros: 0x0102).encode()
    check(header.count == VideoFrameHeader.size && header[0] == 1 && header.last == 0x02, "a frame header is a flag and a big-endian time")
    check(VideoFrameHeader(isKeyframe: false, ptsMicros: 0).encode()[0] == 0, "a non-key frame is flagged 0")

    // Argument parsing
    let args = Arguments(["tbdisplay", "--bitrate", "20", "--any-interface", "--port", "47801", "--name", "x"], flagNames: ["any-interface"])
    check(args.int("bitrate") == 20 && args.string("port") == "47801" && args.string("name") == "x", "values follow their names")
    check(args.flag("any-interface") && !args.flag("no-hidpi"), "flags are on only when given")
    check(args.int("name") == nil && args.int("missing") == nil, "a non-number or an absent option gives nil")
    let dangling = Arguments(["tbdisplay", "--bitrate"], flagNames: [])
    check(dangling.int("bitrate") == nil, "an option with no value does not crash")

    // The failure tracker as it already behaved
    let tracker = FailureTracker(lockout: 60)
    check((0..<4).allSatisfy { _ in !tracker.recordFailure("10.0.0.1") } && !tracker.isBlocked("10.0.0.1"), "four failures do not block")
    check(tracker.recordFailure("10.0.0.1") && tracker.isBlocked("10.0.0.1"), "the fifth failure blocks and says so")
    check(!tracker.isBlocked("10.0.0.2"), "another address is not blocked")
    let forgiving = FailureTracker(lockout: 60)
    for _ in 0..<4 { _ = forgiving.recordFailure("a") }
    forgiving.recordSuccess("a")
    for _ in 0..<4 { _ = forgiving.recordFailure("a") }
    check(!forgiving.isBlocked("a"), "a success clears the count")

    // MARK: written first (the code changed to make these pass)

    // The tracker's lockout ends when the clock says so
    var clock = Date(timeIntervalSince1970: 1_000)
    let timed = FailureTracker(lockout: 60, now: { clock })
    for _ in 0..<5 { _ = timed.recordFailure("h") }
    check(timed.isBlocked("h"), "blocked straight after five failures")
    clock = Date(timeIntervalSince1970: 1_059)
    check(timed.isBlocked("h"), "still blocked 59 seconds later")
    clock = Date(timeIntervalSince1970: 1_061)
    check(!timed.isBlocked("h"), "free again after the lockout")
    for _ in 0..<4 { _ = timed.recordFailure("h") }
    check(!timed.isBlocked("h"), "the count starts again after a lockout")

    // Keeping the pointer on a real display
    let main = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    let above = CGRect(x: -440, y: -1260, width: 2240, height: 1260)
    check(DisplayGeometry.clamp(CGPoint(x: 100, y: 100), to: [main, above]) == CGPoint(x: 100, y: 100), "a point on a display stays where it is")
    check(DisplayGeometry.clamp(CGPoint(x: 100, y: -50), to: [main, above]) == CGPoint(x: 100, y: -50), "the point can cross from one display to the one above")
    check(DisplayGeometry.clamp(CGPoint(x: 2000, y: 500), to: [main]) == CGPoint(x: 1799, y: 500), "beyond the right edge goes to the last pixel")
    check(DisplayGeometry.clamp(CGPoint(x: -300, y: -300), to: [main]) == CGPoint(x: 0, y: 0), "beyond the top left corner goes to the corner")
    check(DisplayGeometry.clamp(CGPoint(x: 1000, y: 1500), to: [main, above]) == CGPoint(x: 1000, y: 1168), "below the bottom picks the nearest display")
    check(DisplayGeometry.clamp(CGPoint(x: 5, y: 5), to: []) == CGPoint(x: 5, y: 5), "with no displays the point is left alone")

    // The saved display position
    check(LayoutMath.restoredOrigin(base: CGRect(x: 0, y: 0, width: 1800, height: 1169), offset: CGPoint(x: -440, y: -1260)) == CGPoint(x: -440, y: -1260), "an offset from the MacBook screen gives the display origin")
    check(LayoutMath.restoredOrigin(base: CGRect(x: 100, y: 50, width: 1800, height: 1169), offset: CGPoint(x: -440, y: -1260)) == CGPoint(x: -340, y: -1210), "the offset follows the MacBook screen if it moves")
    check(LayoutMath.offset(of: CGRect(x: -440, y: -1260, width: 2240, height: 1260), from: CGRect(x: 0, y: 0, width: 1800, height: 1169)) == CGPoint(x: -440, y: -1260), "the offset is measured from the MacBook screen")

    // The heartbeat watchdog
    let t0 = Date(timeIntervalSince1970: 5_000)
    check(!Watchdog.shouldDrop(armed: false, lastMessage: t0, now: t0.addingTimeInterval(60), limit: 4), "an unarmed watchdog never drops")
    check(!Watchdog.shouldDrop(armed: true, lastMessage: t0, now: t0.addingTimeInterval(3.9), limit: 4), "quiet for under four seconds is fine")
    check(Watchdog.shouldDrop(armed: true, lastMessage: t0, now: t0.addingTimeInterval(4.1), limit: 4), "quiet for over four seconds drops the link")
}
