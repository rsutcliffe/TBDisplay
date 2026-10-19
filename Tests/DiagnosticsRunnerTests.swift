// Running the real macOS commands safely.

import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runDiagnosticsRunnerTests() {
    check(DiagnosticsRunner.output(of: "/bin/echo", ["hello"]) == "hello\n", "a command's output is returned")
    check(DiagnosticsRunner.output(of: "/usr/bin/false") == "", "a failing command gives nothing")
    check(DiagnosticsRunner.output(of: "/nonexistent/program") == "", "a missing program gives nothing and does not crash")

    let started = Date()
    let slow = DiagnosticsRunner.output(of: "/bin/sleep", ["5"], timeout: 0.5)
    check(slow == "" && Date().timeIntervalSince(started) < 2, "a command that hangs is stopped after the timeout")

    let partial = DiagnosticsRunner.output(of: "/bin/sh", ["-c", "echo started; sleep 5"], timeout: 0.5)
    check(partial == "", "a command that prints and then hangs gives nothing, not half an answer")

    let big = DiagnosticsRunner.output(of: "/usr/bin/yes", ["abcdefghij"], timeout: 0.5)
    check(big.count > 0 && big.count <= 1_000_000, "a command that never stops is cut at a size limit")

    let report = DiagnosticsRunner.run(appVersion: "1.7.0", protocolVersion: 5)
    check(report.contains("TBDisplay 1.7.0 (protocol 5)"), "a real check names the versions")
    check(report.contains("Thunderbolt"), "a real check says something about Thunderbolt")
}
