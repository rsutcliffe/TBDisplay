#!/bin/zsh
# Draws the app icon (a laptop in front of a big screen, with a Thunderbolt bolt, on an indigo tile)
# and writes AppIcon.icns next to this script. build.sh copies it into the apps.
# Re-run only when changing the design.
set -euo pipefail
cd "$(dirname "$0")"

WORK="$(mktemp -d)"
cat > "$WORK/draw.swift" <<'SWIFT'
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

// Tile: macOS icon grid, 824 pt rounded square centred on the 1024 canvas.
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGradient(starting: color(0x5A4FD8), ending: color(0x1B1650))!.draw(in: tile, angle: -90)

let white = color(0xF4F2FF)

// The big screen behind, with its stand. A gap is cut round the laptop's place, so nothing shows through it.
let gapRect = NSRect(x: 160, y: 250, width: 480, height: 400)
NSGraphicsContext.saveGraphicsState()
let clip = NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024))
clip.append(NSBezierPath(roundedRect: gapRect, xRadius: 50, yRadius: 50))
clip.windingRule = .evenOdd
clip.addClip()
let big = NSBezierPath(roundedRect: NSRect(x: 430, y: 430, width: 400, height: 300), xRadius: 34, yRadius: 34)
color(0x2A2478).setFill(); big.fill()
big.lineWidth = 26; white.setStroke(); big.stroke()
let stand = NSBezierPath(rect: NSRect(x: 612, y: 345, width: 36, height: 85)); white.setFill(); stand.fill()
NSBezierPath(roundedRect: NSRect(x: 540, y: 322, width: 180, height: 30), xRadius: 15, yRadius: 15).fill()
NSGraphicsContext.restoreGraphicsState()

// The laptop in front: screen and base
let screen = NSBezierPath(roundedRect: NSRect(x: 215, y: 340, width: 370, height: 270), xRadius: 32, yRadius: 32)
color(0x120F3C).setFill(); screen.fill()
screen.lineWidth = 26; white.setStroke(); screen.stroke()
white.setFill()
NSBezierPath(roundedRect: NSRect(x: 170, y: 292, width: 460, height: 40), xRadius: 20, yRadius: 20).fill()

// The Thunderbolt bolt on the laptop screen
let bolt = NSBezierPath()
bolt.move(to: NSPoint(x: 420, y: 585)); bolt.line(to: NSPoint(x: 335, y: 455))
bolt.line(to: NSPoint(x: 398, y: 455)); bolt.line(to: NSPoint(x: 370, y: 362))
bolt.line(to: NSPoint(x: 465, y: 502)); bolt.line(to: NSPoint(x: 400, y: 502)); bolt.close()
color(0xFFB02E).setFill(); bolt.fill()

NSGraphicsContext.restoreGraphicsState()
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT

swiftc -O "$WORK/draw.swift" -o "$WORK/draw"
"$WORK/draw" "$WORK/icon_1024.png"

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$WORK/icon_1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$WORK/icon_1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
cp "$WORK/icon_1024.png" AppIcon-preview.png
echo "Wrote Resources/AppIcon.icns"
