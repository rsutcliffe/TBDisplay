// Turns what macOS prints about the cable and the Thunderbolt Bridge into plain sentences.
// Pure text in, findings out, so it can be tested against saved real output.
// Anything it does not recognise becomes a note, never a false alarm.

import Foundation

struct Finding: Equatable {
    enum Level: String { case ok, note, problem }
    let level: Level
    let title: String
    let detail: String
}

enum Diagnostics {
    /// From `system_profiler SPThunderboltDataType`.
    static func thunderbolt(_ text: String) -> [Finding] {
        // "Status:" lines, leaving out "Link Status:"
        let statuses = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("Status:") }
        guard !statuses.isEmpty else {
            return [Finding(level: .note, title: "Could not read the Thunderbolt status",
                            detail: "macOS did not list the Thunderbolt ports in a form TBDisplay understands. This says nothing about your cable.")]
        }
        let connected = statuses.filter { !$0.contains("No device connected") }.count
        if connected == 0 {
            return [Finding(level: .problem, title: "No Thunderbolt device on any port",
                            detail: "The other Mac is not seen on any of this Mac's \(statuses.count) Thunderbolt ports. Check that the cable is a Thunderbolt or USB4 cable (a charging cable is not enough), that both ends are fully in, and that the iMac end is in a Thunderbolt port.")]
        }
        let ports = connected == 1 ? "1 of \(statuses.count) ports reports a connected device."
                                   : "\(connected) of \(statuses.count) ports report connected devices."
        return [Finding(level: .ok, title: "Thunderbolt link found", detail: ports)]
    }

    /// From `system_profiler SPUSBHostDataType`. A Mac that shows up here at USB 2 speed means the cable is not Thunderbolt.
    static func usb(_ text: String) -> [Finding] {
        var device: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.contains("Bus:") { device = nil; continue }
            if line.hasSuffix(":"), line.contains("Mac") { device = String(line.dropLast()); continue }
            if let device, line.hasPrefix("Link Speed:"), line.contains("480 Mb/s") {
                return [Finding(level: .problem, title: "The other Mac is connected over USB 2 only",
                                detail: "\(device) is visible to this Mac only as a USB 2 device (480 Mb/s), so the Thunderbolt part of the link has not formed. That can be the cable, or a stale Thunderbolt Bridge on either Mac.")]
            }
        }
        return []
    }

    /// From `ifconfig bridge0`.
    static func bridge(_ text: String) -> [Finding] {
        if text.contains("does not exist") {
            return [Finding(level: .note, title: "No Thunderbolt Bridge on this Mac",
                            detail: "Turn Thunderbolt Bridge on in System Settings > Network.")]
        }
        if text.contains("status: inactive") {
            return [Finding(level: .problem, title: "Thunderbolt Bridge is not active",
                            detail: "The bridge has no link. The other Mac may be asleep or not connected, or the Thunderbolt link has not formed.")]
        }
        if text.contains("status: active") {
            let address = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("inet ") }
                .flatMap { $0.split(separator: " ").dropFirst().first.map(String.init) }
            if let address {
                return [Finding(level: .ok, title: "Thunderbolt Bridge is up", detail: "Address \(address).")]
            }
            return [Finding(level: .note, title: "Thunderbolt Bridge has no address yet", detail: "Wait a few seconds and check again.")]
        }
        return [Finding(level: .note, title: "Could not read the Thunderbolt Bridge status", detail: "macOS gave an answer TBDisplay does not understand.")]
    }

    /// What has worked in practice when the Thunderbolt link will not form. Only offered when the cable-level checks found a problem.
    static func advice(_ findings: [Finding]) -> [Finding] {
        let linkProblems: Set<String> = ["No Thunderbolt device on any port", "The other Mac is connected over USB 2 only", "Thunderbolt Bridge is not active"]
        guard findings.contains(where: { $0.level == .problem && linkProblems.contains($0.title) }) else { return [] }
        return [Finding(level: .note, title: "What has worked",
                        detail: "Unplug the cable at the MacBook. On the MacBook, open System Settings, then Network, use the ... menu to delete Thunderbolt Bridge, then add it again with the + button. Plug the cable back in and check again. If that does not help, do the same on the iMac, then restart both Macs, and only then try another Thunderbolt 4 cable (40 Gbps, 1 metre or shorter).")]
    }

    /// One line for the top of the report.
    static func summary(_ findings: [Finding]) -> String {
        if let problem = findings.first(where: { $0.level == .problem }) { return "Problem found: \(problem.title)" }
        if findings.isEmpty { return "Nothing to report." }
        if findings.allSatisfy({ $0.level == .ok }) { return "Everything looks right." }
        return "Nothing wrong found, but see the notes."
    }

    static func report(_ findings: [Finding], appVersion: String, protocolVersion: UInt32) -> String {
        let label: [Finding.Level: String] = [.ok: "OK", .note: "Note", .problem: "Problem"]
        var text = "TBDisplay \(appVersion) (protocol \(protocolVersion))\n\(summary(findings))\n\n"
        for finding in findings {
            text += "\(label[finding.level] ?? ""): \(finding.title)\n  \(finding.detail)\n\n"
        }
        return text
    }
}
