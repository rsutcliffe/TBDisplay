// Runs every unit test suite. Run with: ./build.sh test

import Foundation

runSharedTests()
runClientModelTests()
runPairingProtocolTests()
runPairingNetworkTests()
runPairingFlowModelTests()
runPairingSupportTests()
runUpdateCheckTests()
runLogFileTests()
runConnectionGateTests()
runConnectionModeTests()
runLoginItemTests()
runVersionTests()
runDiagnosticsTests()
runDiagnosticsRunnerTests()
runChecklistTests()
runRetroTests()

print(failures == 0 ? "All checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
