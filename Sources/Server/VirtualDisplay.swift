// Creates a virtual display on the MacBook sized to match the iMac panel.
// macOS treats it as a real extended display, so windows and the cursor move onto it
// through the normal display arrangement in System Settings.

import AppKit
import CoreGraphics

final class VirtualDisplay {
    private var display: CGVirtualDisplay?
    let pixelWidth: Int
    let pixelHeight: Int

    var displayID: CGDirectDisplayID { display?.displayID ?? kCGNullDirectDisplay }

    /// Must be called on the main thread.
    init?(name: String, pixelWidth: Int, pixelHeight: Int, refreshRate: Double, hiDPI: Bool, scale: Int = 2, pixelsPerInch: Double = 218, quiet: Bool = false) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(pixelWidth)
        descriptor.maxPixelsHigh = UInt32(pixelHeight)
        let mmPerPixel = 25.4 / pixelsPerInch
        descriptor.sizeInMillimeters = CGSize(width: Double(pixelWidth) * mmPerPixel,
                                              height: Double(pixelHeight) * mmPerPixel)
        descriptor.vendorID = 0x7462   // arbitrary, not a real vendor
        descriptor.productID = 0x6470
        descriptor.serialNum = 0x0001
        descriptor.terminationHandler = { _, _ in
            log("macOS removed the virtual display")
        }

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            if !quiet { log("Could not create the virtual display") }
            return nil
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        var modes = [CGVirtualDisplayMode(width: UInt32(pixelWidth), height: UInt32(pixelHeight), refreshRate: refreshRate)]
        if hiDPI && scale > 1 {
            // With hiDPI on, a point-sized mode is backed by the full pixel size.
            modes.insert(CGVirtualDisplayMode(width: UInt32(pixelWidth / scale), height: UInt32(pixelHeight / scale), refreshRate: refreshRate), at: 0)
        }
        settings.modes = modes
        guard display.apply(settings) else {
            log("Could not apply settings to the virtual display")
            return nil
        }
        self.display = display
    }

    /// Picks the mode whose backing store is the full panel resolution and whose
    /// "looks like" width is pixelWidth / scale (for example 2240 x 1260 on a 4.5K iMac).
    @discardableResult
    func selectMode(scale: Int, quiet: Bool = false) -> Bool {
        let wantPoints = pixelWidth / max(scale, 1)
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            if !quiet { log("Could not list display modes") }
            return false
        }
        guard let mode = modes.first(where: { $0.pixelWidth == pixelWidth && $0.width == wantPoints }) else {
            let available = modes.map { "\($0.width)x\($0.height) (\($0.pixelWidth)x\($0.pixelHeight) px)" }
            if !quiet { log("No \(wantPoints)-point-wide mode found. Available: \(available.joined(separator: ", "))") }
            return false
        }
        let result = CGDisplaySetDisplayMode(displayID, mode, nil)
        if result == .success {
            log("Virtual display set to look like \(mode.width)x\(mode.height) at \(mode.pixelWidth)x\(mode.pixelHeight) pixels")
            return true
        }
        log("Could not set display mode (error \(result.rawValue))")
        return false
    }

    // MARK: Arrangement

    private static var layoutFile: URL {
        if let path = ProcessInfo.processInfo.environment["TBDISPLAY_LAYOUT_FILE"] { return URL(fileURLWithPath: path) }   // used by the tests
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tbdisplay/layout.json")
    }

    private static var builtInID: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Puts the display back where the user left it last time, relative to the MacBook screen.
    /// Does nothing until a position has been saved, so it never overrides what macOS chose. Main thread only.
    func restoreArrangement() {
        guard let builtIn = Self.builtInID, display != nil,
              let data = try? Data(contentsOf: Self.layoutFile),
              let saved = try? JSONDecoder().decode([String: Double].self, from: data),
              let dx = saved["dx"], let dy = saved["dy"] else { return }
        let base = CGDisplayBounds(builtIn)
        let target = LayoutMath.restoredOrigin(base: base, offset: CGPoint(x: dx, y: dy))
        guard CGDisplayBounds(displayID).origin != target else { return }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        guard CGConfigureDisplayOrigin(config, displayID, Int32(target.x.rounded()), Int32(target.y.rounded())) == .success,
              CGCompleteDisplayConfiguration(config, .forSession) == .success else {
            CGCancelDisplayConfiguration(config)
            log("Could not set the display position")
            return
        }
        log("Display placed at \(Int(target.x)),\(Int(target.y)) (saved position)")
    }

    /// Remembers where the display sits relative to the MacBook screen. Main thread only.
    func saveArrangement() {
        guard let builtIn = Self.builtInID, display != nil else { return }
        let mine = CGDisplayBounds(displayID), base = CGDisplayBounds(builtIn)
        let moved = LayoutMath.offset(of: mine, from: base)
        let offset = ["dx": moved.x, "dy": moved.y]
        try? FileManager.default.createDirectory(at: Self.layoutFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(offset).write(to: Self.layoutFile)
        log("Saved display position \(Int(offset["dx"]!)),\(Int(offset["dy"]!)) relative to the MacBook screen")
    }

    /// Removes the display. Windows on it move back to the MacBook screen. Main thread only.
    func remove() {
        display = nil
    }
}
