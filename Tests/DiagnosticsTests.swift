// Turning what macOS prints about the cable and the bridge into plain sentences.
// The "no device", USB and inactive-bridge fixtures are real captures. The files marked SYNTHETIC are what a
// working link is expected to look like: they must be checked against the real output once a cable is in.

import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runDiagnosticsTests() {
    func fixture(_ name: String) -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures")
        return (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? "FIXTURE MISSING \(name)"
    }

    // Thunderbolt ports
    let none = Diagnostics.thunderbolt(fixture("thunderbolt-no-device.txt"))
    check(none.count == 1 && none[0].level == .problem && none[0].title == "No Thunderbolt device on any port", "no device on any port is a problem")
    check(none.first?.detail.contains("Thunderbolt or USB4 cable") == true && none.first?.detail.contains("charging") == true, "the advice mentions the cable type")
    let linked = Diagnostics.thunderbolt(fixture("thunderbolt-connected.SYNTHETIC.txt"))
    check(linked.count == 1 && linked[0].level == .ok && linked[0].title == "Thunderbolt link found", "a connected port is good news (synthetic fixture)")
    check(linked.first?.detail == "1 of 3 ports reports a connected device.", "it says how many ports (synthetic fixture)")
    let unreadable = Diagnostics.thunderbolt("something else entirely")
    check(unreadable.count == 1 && unreadable[0].level == .note && unreadable[0].title == "Could not read the Thunderbolt status", "an unknown format is a note, not a false alarm")
    check(Diagnostics.thunderbolt("").first?.level == .note, "empty output is a note")

    // USB
    let usb2 = Diagnostics.usb(fixture("usb-imac-usb2-only.txt"))
    check(usb2.count == 1 && usb2[0].level == .problem && usb2[0].title == "The other Mac is connected over USB 2 only", "a Mac seen at 480 Mb/s is a problem")
    check(usb2.first?.detail.contains("480 Mb/s") == true && usb2.first?.detail.contains("stale Thunderbolt Bridge") == true, "the finding names the speed and says the bridge can be stale, not only the cable")
    check(Diagnostics.usb(fixture("usb-nothing-attached.txt")).isEmpty, "no other Mac on USB says nothing")
    check(Diagnostics.usb(fixture("usb-imac-usb2-only.txt").replacingOccurrences(of: "480 Mb/s", with: "10 Gb/s")).isEmpty, "a fast USB link is not flagged")

    // The bridge
    let down = Diagnostics.bridge(fixture("bridge0-inactive.txt"))
    check(down.count == 1 && down[0].level == .problem && down[0].title == "Thunderbolt Bridge is not active", "an inactive bridge is a problem")
    let up = Diagnostics.bridge(fixture("bridge0-active.SYNTHETIC.txt"))
    check(up.count == 1 && up[0].level == .ok && up[0].title == "Thunderbolt Bridge is up" && up[0].detail.contains("169.254.31.7"), "an active bridge shows its address (synthetic fixture)")
    let noAddress = Diagnostics.bridge("bridge0: flags=8863<UP>\n\tstatus: active\n")
    check(noAddress.count == 1 && noAddress[0].level == .note && noAddress[0].title == "Thunderbolt Bridge has no address yet", "an active bridge with no address asks you to wait")
    let missing = Diagnostics.bridge("ifconfig: interface bridge0 does not exist")
    check(missing.count == 1 && missing[0].level == .note && missing[0].title == "No Thunderbolt Bridge on this Mac" && missing[0].detail.contains("System Settings"), "no bridge at all points to System Settings")

    // The one-line verdict and the report
    let problem = Finding(level: .problem, title: "Bad cable", detail: "x")
    let good = Finding(level: .ok, title: "Fine", detail: "y")
    let note = Finding(level: .note, title: "Hmm", detail: "z")
    check(Diagnostics.summary([good, problem, note]) == "Problem found: Bad cable", "the verdict names the first problem")
    check(Diagnostics.summary([good, good]) == "Everything looks right.", "all good says so")
    check(Diagnostics.summary([good, note]) == "Nothing wrong found, but see the notes.", "notes only says so")
    check(Diagnostics.summary([]) == "Nothing to report.", "no findings says so")
    let report = Diagnostics.report([problem, good, note], appVersion: "1.7.0", protocolVersion: 5)
    check(report.contains("TBDisplay 1.7.0 (protocol 5)"), "the report states the versions")
    check(report.contains("Problem: Bad cable") && report.contains("OK: Fine") && report.contains("Note: Hmm"), "each finding is labelled")
    check(report.contains("x") && report.contains("y") && report.contains("z"), "each finding's advice is included")

    // When the link will not form, the report says what has worked
    let cableProblem = Finding(level: .problem, title: "Thunderbolt Bridge is not active", detail: "x")
    let advised = Diagnostics.advice([cableProblem])
    check(advised.count == 1 && advised[0].level == .note && advised[0].title == "What has worked", "a cable-level problem gets one advice note")
    check(advised.first?.detail.contains("delete Thunderbolt Bridge") == true && advised.first?.detail.contains("add it again") == true && advised.first?.detail.contains("Unplug the cable at the MacBook") == true, "the advice says to unplug, delete and re-add the bridge")
    check(advised.first?.detail.contains("Thunderbolt 4 cable") == true, "the cable comes last in the advice")
    check(Diagnostics.advice([Finding(level: .problem, title: "No Thunderbolt device on any port", detail: "x")]).count == 1, "no device on any port gets the advice")
    check(Diagnostics.advice([Finding(level: .problem, title: "The other Mac is connected over USB 2 only", detail: "x")]).count == 1, "USB 2 only gets the advice")
    check(Diagnostics.advice([Finding(level: .ok, title: "Thunderbolt Bridge is up", detail: "x")]).isEmpty, "a working link gets no advice")
    check(Diagnostics.advice([Finding(level: .note, title: "Thunderbolt Bridge is not active", detail: "x")]).isEmpty, "a note is not a problem, so no advice")
    check(Diagnostics.advice([cableProblem, cableProblem]).count == 1, "several cable problems still give one advice note")
    check(!Diagnostics.usb("  USB 3.1 Bus:\n    iMac:\n      Link Speed: 480 Mb/s\n").map(\.detail).joined().contains("Use a Thunderbolt 4 cable"), "the USB 2 wording no longer blames the cable first")
}
