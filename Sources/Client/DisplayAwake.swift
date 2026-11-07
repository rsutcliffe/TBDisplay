// Holds the iMac's display awake while the MacBook's picture is on it, and lets go the rest of the time, so the iMac
// sleeps by itself when nothing is showing. (Before 1.10.3 it was held from launch, even when nothing was streaming.)
// The hold only stops the screen saver from starting. One that started while the picture was away (the MacBook's
// display slept and the stream dropped for minutes) stays on top of the picture, so while streaming it is closed.

import AppKit
import Foundation
import IOKit.pwr_mgt

final class DisplayAwake {
    private var assertion: IOPMAssertionID = 0
    private var held = false
    private var timer: Timer?

    func set(_ on: Bool) {
        guard on != held else { return }
        if on {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "tbdisplay is showing the MacBook display" as CFString, &assertion)
            var activity: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("tbdisplay picture started" as CFString, kIOPMUserActiveLocal, &activity)
            log("Holding this iMac awake while the picture is on.")
            closeScreenSaver()
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.closeScreenSaver() }
        } else {
            IOPMAssertionRelease(assertion)
            timer?.invalidate()
            timer = nil
            log("No longer holding this iMac awake.")
        }
        held = on
    }

    private func closeScreenSaver() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.ScreenSaver.Engine") {
            log("Closing the screen saver, because the MacBook's picture is on.")
            app.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if !app.isTerminated { app.forceTerminate() } }
        }
    }
}
