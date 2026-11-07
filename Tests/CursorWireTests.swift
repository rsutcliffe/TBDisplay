// The pointer travels apart from the video: a small position message and a shape message.

import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runCursorWireTests() {
    // Position round trip
    let position = CursorPosition(visible: true, x: 250_000, y: 750_000)
    check((try? CursorPosition.decode(position.encode())) == position, "a cursor position survives encoding")
    let hidden = CursorPosition(visible: false, x: 0, y: 0)
    check((try? CursorPosition.decode(hidden.encode())) == hidden, "a hidden cursor survives encoding")
    check((try? CursorPosition.decode(Data([1, 0, 0]))) == nil, "a truncated position is refused")
    check(!CursorPosition(visible: true, x: -3_000_000, y: 0).isSane, "a position far off the screen is not sane")
    check(CursorPosition(visible: true, x: 1_000_000, y: 1_000_000).isSane, "the bottom right corner is sane")

    // Shape round trip
    let png = Data((0..<500).map { UInt8($0 % 251) })
    let shape = CursorShape(hotspotX: 500, hotspotY: 500, scale: 2, png: png)
    check((try? CursorShape.decode(shape.encode())) == shape, "a cursor shape survives encoding")
    check((try? CursorShape.decode(Data([0, 0]))) == nil, "a truncated shape is refused")
    let tooBig = CursorShape(hotspotX: 0, hotspotY: 0, scale: 2, png: Data(count: CursorShape.maxPNGBytes + 1))
    check(!tooBig.isSane, "a shape over the size cap is not sane")
    check((try? CursorShape.decode(tooBig.encode())) == nil, "a shape over the size cap is refused on arrival")
    check(!CursorShape(hotspotX: 0, hotspotY: 0, scale: 0, png: png).isSane, "a shape with scale 0 is not sane")
    check(!CursorShape(hotspotX: 0, hotspotY: 0, scale: 2, png: Data()).isSane, "a shape with no image is not sane")

    // Tracker: pointer point on the Mac desktop to a share of the virtual display
    let bounds = CGRect(x: 1000, y: 0, width: 2240, height: 1260)
    var tracker = CursorTracker()
    let centre = tracker.update(point: CGPoint(x: 2120, y: 630), bounds: bounds)
    check(centre == CursorPosition(visible: true, x: 500_000, y: 500_000), "the middle of the display maps to 500000, 500000")
    check(tracker.update(point: CGPoint(x: 2120, y: 630), bounds: bounds) == nil, "the same position is not sent twice")
    let out = tracker.update(point: CGPoint(x: 10, y: 10), bounds: bounds)
    check(out?.visible == false, "a pointer on another screen hides the cursor")
    check(tracker.update(point: CGPoint(x: 20, y: 20), bounds: bounds) == nil, "staying on another screen sends nothing more")
    let back = tracker.update(point: CGPoint(x: 2120, y: 630), bounds: bounds)
    check(back == CursorPosition(visible: true, x: 500_000, y: 500_000), "coming back to the display shows the cursor again")
    var fresh = CursorTracker()
    check(fresh.update(point: .zero, bounds: .zero)?.visible != true, "a display with no size never shows the cursor")
    var corner = CursorTracker()
    check(corner.update(point: CGPoint(x: 1000, y: 0), bounds: bounds) == CursorPosition(visible: true, x: 0, y: 0),
          "the top left corner maps to 0, 0")
}
