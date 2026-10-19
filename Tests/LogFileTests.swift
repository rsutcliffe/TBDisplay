// The log file: apps opened from Applications have no terminal, so their log has to be readable afterwards.

import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runLogFileTests() {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    // Lines are written in order, and the folder is made if it is missing
    let url = dir.appendingPathComponent("logs/server.log")
    let log = LogFile(url: url)
    log.append("first\n")
    log.append("second\n")
    check((try? String(contentsOf: url, encoding: .utf8)) == "first\nsecond\n", "lines are written in order, and the folder is created")

    // Only the owner reads it: it holds addresses of other computers
    let mode = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue
    check(mode == 0o600, "the log file is readable by the owner only")

    // At the size limit the file is moved aside and a new one starts. One older copy is kept, no more.
    let small = LogFile(url: dir.appendingPathComponent("small.log"), maxBytes: 30)
    for i in 1...6 { small.append("line number \(i)\n") }       // 14 bytes each
    let current = (try? String(contentsOf: dir.appendingPathComponent("small.log"), encoding: .utf8)) ?? ""
    let older = (try? String(contentsOf: dir.appendingPathComponent("small.log.1"), encoding: .utf8)) ?? ""
    check(current.hasSuffix("line number 6\n"), "after a rotation the newest line is in the current file")
    check(!older.isEmpty && (older + current).contains("line number 5"), "the older lines are in the kept copy")
    check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("small.log.2").path), "only one older copy is kept")
    check(current.utf8.count <= 30, "the current file stays under the limit")

    // A failure to write is ignored
    let broken = LogFile(url: URL(fileURLWithPath: "/proc-does-not-exist/x/server.log"))
    broken.append("nobody will read this\n")
    check(true, "a log file that cannot be written does not stop the app")

    // Where the file lives
    check(LogFile.defaultURL(name: "server").path.hasSuffix("/Library/Logs/TBDisplay/server.log") || ProcessInfo.processInfo.environment["TBDISPLAY_LOG_DIR"] != nil,
          "by default the log is in the user's Library/Logs/TBDisplay folder")
    setenv("TBDISPLAY_LOG_DIR", dir.path, 1)
    check(LogFile.defaultURL(name: "client").path == dir.appendingPathComponent("client.log").path, "TBDISPLAY_LOG_DIR moves the log folder (for tests)")
    unsetenv("TBDISPLAY_LOG_DIR")
}
