// Helpers shared by every test suite.

import Foundation

var failures = 0

func check(_ condition: Bool, _ what: String) {
    if condition { print("ok   \(what)") } else { print("FAIL \(what)"); failures += 1 }
}

/// A fresh empty folder for a test, removed by the caller.
func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tbdisplay-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
