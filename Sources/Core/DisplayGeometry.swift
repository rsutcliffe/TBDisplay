// Small pieces of arithmetic the server and client rely on, kept apart so they can be tested.

import CoreGraphics
import Foundation

enum DisplayGeometry {
    /// Keeps a point on a real display: unchanged if it is on one, otherwise moved to the nearest edge pixel.
    static func clamp(_ point: CGPoint, to rects: [CGRect]) -> CGPoint {
        if rects.contains(where: { $0.contains(point) }) { return point }
        func clamped(_ r: CGRect) -> CGPoint {
            CGPoint(x: min(max(point.x, r.minX), r.maxX - 1), y: min(max(point.y, r.minY), r.maxY - 1))
        }
        let best = rects.map(clamped).min { hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y) }
        return best ?? point
    }
}

enum LayoutMath {
    /// Where the virtual display goes, given the MacBook screen and the offset saved from it.
    static func restoredOrigin(base: CGRect, offset: CGPoint) -> CGPoint {
        CGPoint(x: base.minX + offset.x, y: base.minY + offset.y)
    }

    /// The offset to save: how far the virtual display's corner is from the MacBook screen's corner.
    static func offset(of mine: CGRect, from base: CGRect) -> CGPoint {
        CGPoint(x: mine.minX - base.minX, y: mine.minY - base.minY)
    }
}

enum Watchdog {
    /// Whether the client should treat the link as dead: it has heard from the MacBook before, and not lately.
    static func shouldDrop(armed: Bool, lastMessage: Date, now: Date, limit: TimeInterval) -> Bool {
        armed && now.timeIntervalSince(lastMessage) > limit
    }
}
