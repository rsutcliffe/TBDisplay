// swift-tools-version: 5.9
// Opens in Xcode (File > Open this folder), and `swift test` runs every unit check.
// This package holds the logic with no windows: the shared protocol and the Core folder. The two apps are
// still built by ./build.sh, because the virtual display needs a private Apple header that Swift packages
// cannot import into an app target.

import PackageDescription

let package = Package(
    name: "TBDisplay",
    platforms: [.macOS(.v14)],
    products: [.library(name: "TBCore", targets: ["TBCore"])],
    targets: [
        .target(name: "TBCore", path: "Sources", sources: ["Shared", "Core"]),
        .testTarget(
            name: "TBCoreTests",
            dependencies: ["TBCore"],
            path: "Tests",
            exclude: ["main.swift", "probe", "fixtures", "all.sh", "checklist_ui.sh", "client_window.sh", "connection_check_ui.sh", "input_gate.sh", "loopback.sh", "pairing_ui.sh", "release_script_test.sh"],
            sources: ["ChecklistTests.swift", "ClientModelTests.swift", "DiagnosticsRunnerTests.swift", "DiagnosticsTests.swift", "LogFileTests.swift", "ConnectionGateTests.swift", "ConnectionModeTests.swift", "LoginItemTests.swift", "PairingFlowModelTests.swift", "PairingNetworkTests.swift", "PairingProtocolTests.swift", "PairingSupportTests.swift", "RetroTests.swift", "SharedTests.swift", "UpdateCheckTests.swift", "TestSupport.swift", "VersionTests.swift"] + ["XCTests"]
        ),
    ]
)
