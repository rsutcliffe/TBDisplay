// Runs each of the project's check suites inside XCTest, so Xcode's test navigator and `swift test` see them.
// The checks themselves live in the files one folder up and are the same ones ./build.sh test runs.

import XCTest
@testable import TBCore

final class SuiteTests: XCTestCase {
    /// A suite passes when it adds no failures. Each failed check is printed above with its description.
    private func run(_ name: String, _ suite: () -> Void) {
        let before = failures
        suite()
        XCTAssertEqual(failures, before, "\(name): \(failures - before) check(s) failed. Read the FAIL lines in the log.")
    }

    func testShared() { run("Shared", runSharedTests) }
    func testClientModel() { run("ClientModel", runClientModelTests) }
    func testPairingProtocol() { run("PairingProtocol", runPairingProtocolTests) }
    func testPairingNetwork() { run("PairingNetwork", runPairingNetworkTests) }
    func testPairingFlowModel() { run("PairingFlowModel", runPairingFlowModelTests) }
    func testPairingSupport() { run("PairingSupport", runPairingSupportTests) }
    func testLogFile() { run("LogFile", runLogFileTests) }
    func testConnectionGate() { run("ConnectionGate", runConnectionGateTests) }
    func testLoginItem() { run("LoginItem", runLoginItemTests) }
    func testUpdateCheck() { run("UpdateCheck", runUpdateCheckTests) }
    func testVersion() { run("Version", runVersionTests) }
    func testDiagnostics() { run("Diagnostics", runDiagnosticsTests) }
    func testDiagnosticsRunner() { run("DiagnosticsRunner", runDiagnosticsRunnerTests) }
    func testChecklist() { run("Checklist", runChecklistTests) }
    func testRetro() { run("Retro", runRetroTests) }
}
