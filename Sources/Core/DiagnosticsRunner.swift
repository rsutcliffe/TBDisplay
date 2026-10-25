// Runs the macOS commands the connection check reads, safely: a command that is missing, fails, hangs or
// never stops cannot freeze the window or flood memory.

import Foundation

enum DiagnosticsRunner {
    static let sizeLimit = 1_000_000

    /// What the command printed (output and errors together). Empty if it could not start or took longer than `timeout`.
    /// A command that prints without end is stopped at `sizeLimit` and what it printed so far is returned.
    static func output(of path: String, _ arguments: [String] = [], timeout: TimeInterval = 10) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let lock = NSLock()
        var data = Data()
        var capped = false
        let done = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); defer { lock.unlock() }
            if chunk.isEmpty { return }
            data.append(chunk.prefix(sizeLimit - data.count))
            if data.count >= sizeLimit, !capped {
                capped = true
                if process.isRunning { process.terminate() }
            }
        }
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return "" }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            pipe.fileHandleForReading.readabilityHandler = nil
            lock.lock(); defer { lock.unlock() }
            return capped ? String(decoding: data, as: UTF8.self) : ""
        }
        Thread.sleep(forTimeInterval: 0.05)            // let the last chunk arrive
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    /// The whole check on this Mac: reads the three sources and builds the report.
    /// `extra` is what the app learned by really trying to connect (or about itself): it goes first, so the top line is the real reason.
    static func run(appVersion: String, protocolVersion: UInt32, extra: (findings: [Finding], outcome: ProbeOutcome?) = ([], nil)) -> String {
        let thunderbolt = output(of: "/usr/sbin/system_profiler", ["SPThunderboltDataType"], timeout: 20)
        let usb = output(of: "/usr/sbin/system_profiler", ["SPUSBHostDataType"], timeout: 20)
        let bridge = output(of: "/sbin/ifconfig", ["bridge0"], timeout: 5)
        var cable = Diagnostics.thunderbolt(thunderbolt) + Diagnostics.usb(usb) + Diagnostics.bridge(bridge)
        if let outcome = extra.outcome { cable = ConnectionProbe.reconcile(cable: cable, outcome: outcome) }
        let findings = extra.findings + cable
        return Diagnostics.report(findings, appVersion: appVersion, protocolVersion: protocolVersion)
    }
}
