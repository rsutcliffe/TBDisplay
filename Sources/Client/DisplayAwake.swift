// Holds the iMac's display awake while the MacBook's picture is on it, and lets go the rest of the time, so the iMac
// sleeps by itself when nothing is showing. (Before 1.10.3 it was held from launch, even when nothing was streaming.)

import Foundation
import IOKit.pwr_mgt

final class DisplayAwake {
    private var assertion: IOPMAssertionID = 0
    private var held = false

    func set(_ on: Bool) {
        guard on != held else { return }
        if on {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "tbdisplay is showing the MacBook display" as CFString, &assertion)
            log("Holding this iMac awake while the picture is on.")
        } else {
            IOPMAssertionRelease(assertion)
            log("No longer holding this iMac awake.")
        }
        held = on
    }
}
