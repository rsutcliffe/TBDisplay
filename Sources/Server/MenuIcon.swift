// The menu bar glyph: a laptop in front of a larger screen. The big screen is filled while an iMac is connected.
// Drawn in code as a template image, so macOS tints it for light, dark and dimmed states.

import AppKit

enum MenuIcon {
    static func image(connected: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { _ in
            let line: CGFloat = 1.4
            NSColor.black.set()

            // The big screen behind (the iMac)
            let big = NSBezierPath(roundedRect: NSRect(x: 9, y: 5.2, width: 12, height: 9.3), xRadius: 1.6, yRadius: 1.6)
            if connected { big.fill() } else { big.lineWidth = line; big.stroke() }
            let stand = NSBezierPath()
            stand.move(to: NSPoint(x: 15, y: 5.2)); stand.line(to: NSPoint(x: 15, y: 3.2))
            stand.move(to: NSPoint(x: 12.4, y: 2.8)); stand.line(to: NSPoint(x: 17.6, y: 2.8))
            stand.lineWidth = line; stand.lineCapStyle = .round; stand.stroke()

            // Clear a gap around the laptop so the two shapes read as separate
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: NSRect(x: -0.4, y: 0.4, width: 13.2, height: 11.8), xRadius: 2.2, yRadius: 2.2).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            // The laptop in front (the MacBook): screen and base
            NSColor.black.set()
            let screen = NSBezierPath(roundedRect: NSRect(x: 1.6, y: 4.2, width: 9.4, height: 6.6), xRadius: 1.2, yRadius: 1.2)
            screen.lineWidth = line; screen.stroke()
            let base = NSBezierPath(roundedRect: NSRect(x: 0.4, y: 2.0, width: 11.8, height: 1.6), xRadius: 0.8, yRadius: 0.8)
            base.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
