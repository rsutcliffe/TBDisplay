// The pointer is not part of the video. The MacBook sends where it is and what it looks like as two small
// messages, and the iMac draws it on top of the picture, so it moves without waiting for a video frame.

import CoreGraphics
import Foundation

/// Where the pointer is, as a share of the virtual display (millionths of its width and height).
struct CursorPosition: Equatable {
    var visible: Bool
    var x: Int32
    var y: Int32

    /// A little past the edges is fine, since a hotspot can sit on the border. Anything else is not a real pointer.
    var isSane: Bool { (-1_000_000...2_000_000).contains(x) && (-1_000_000...2_000_000).contains(y) }

    func encode() -> Data {
        var w = ByteWriter()
        w.u8(visible ? 1 : 0); w.u32(UInt32(bitPattern: x)); w.u32(UInt32(bitPattern: y))
        return w.data
    }

    static func decode(_ data: Data) throws -> CursorPosition {
        var r = ByteReader(data)
        let position = CursorPosition(visible: try r.u8() != 0, x: Int32(bitPattern: try r.u32()), y: Int32(bitPattern: try r.u32()))
        guard position.isSane else { throw ProtocolError.tooLarge }
        return position
    }
}

/// What the pointer looks like: a PNG, the point inside it that is the tip (hundredths of a point), and its pixel scale.
struct CursorShape: Equatable {
    static let maxPNGBytes = 64 * 1024

    var hotspotX: UInt32
    var hotspotY: UInt32
    var scale: UInt8
    var png: Data

    var isSane: Bool { (1...3).contains(scale) && !png.isEmpty && png.count <= CursorShape.maxPNGBytes }

    func encode() -> Data {
        var w = ByteWriter()
        w.u32(hotspotX); w.u32(hotspotY); w.u8(scale); w.bytes(png)
        return w.data
    }

    static func decode(_ data: Data) throws -> CursorShape {
        var r = ByteReader(data)
        let shape = CursorShape(hotspotX: try r.u32(), hotspotY: try r.u32(), scale: try r.u8(), png: Data(r.remaining))
        guard shape.isSane else { throw ProtocolError.tooLarge }
        return shape
    }
}

/// Turns the pointer's place on the MacBook desktop into a message, and stays quiet when nothing changed.
struct CursorTracker {
    private var last: CursorPosition?

    /// Returns the message to send, or nil when it would repeat the last one.
    mutating func update(point: CGPoint, bounds: CGRect) -> CursorPosition? {
        let next: CursorPosition
        if bounds.width > 0, bounds.height > 0, bounds.contains(point) {
            next = CursorPosition(visible: true,
                                  x: Int32(((point.x - bounds.minX) / bounds.width * 1_000_000).rounded()),
                                  y: Int32(((point.y - bounds.minY) / bounds.height * 1_000_000).rounded()))
        } else {
            next = CursorPosition(visible: false, x: 0, y: 0)
        }
        if next == last { return nil }
        last = next
        return next
    }

    /// Forget the last message, so the next update is sent. Used when a new iMac connects.
    mutating func reset() { last = nil }
}
