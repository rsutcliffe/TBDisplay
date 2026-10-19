// Telling the person which side is out of date.

import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runVersionTests() {
    let hello = Hello(version: 5, pixelWidth: 4480, pixelHeight: 2520, scale: 2, refreshRate: 60, appVersion: "1.7.0")
    let decoded = try? Hello.decode(hello.encode())
    check(decoded?.appVersion == "1.7.0", "the app version travels in the hello")
    check(decoded?.pixelWidth == 4480 && decoded?.refreshRate == 60, "the other hello fields still arrive")

    // A hello from before the version existed is 20 bytes: it must still decode, with no version
    let old = hello.encode().prefix(20)
    let oldDecoded = try? Hello.decode(Data(old))
    check(oldDecoded?.appVersion == "" && oldDecoded?.pixelWidth == 4480, "an old 20 byte hello decodes with no version")
    check((try? Hello.decode(Data(old.prefix(12)))) == nil, "a truncated hello is refused")
    var long = Hello(version: 5, pixelWidth: 4480, pixelHeight: 2520, scale: 2, refreshRate: 60, appVersion: String(repeating: "x", count: 500))
    check((try? Hello.decode(long.encode()))?.appVersion.count ?? 999 <= 32, "a huge version string is cut short")
    long.appVersion = "é1.7"
    check((try? Hello.decode(long.encode()))?.appVersion == "é1.7", "a version with a non-ASCII letter survives")

    let older = VersionCheck.refusalNotice(clientProtocol: 4, clientApp: "1.6.0", serverProtocol: 5, serverApp: "1.7.0")
    check(older == "This iMac has TBDisplay 1.6.0 and the MacBook has 1.7.0. Update TBDisplay on the iMac.", "an older client is told to update")
    let newer = VersionCheck.refusalNotice(clientProtocol: 6, clientApp: "1.9.0", serverProtocol: 5, serverApp: "1.7.0")
    check(newer == "This iMac has TBDisplay 1.9.0 and the MacBook has 1.7.0. Update TBDisplay on the MacBook.", "a newer client sends the MacBook to be updated")
    let unknown = VersionCheck.refusalNotice(clientProtocol: 3, clientApp: "", serverProtocol: 5, serverApp: "1.7.0")
    check(unknown == "This iMac has an older TBDisplay than the MacBook (1.7.0). Update TBDisplay on the iMac.", "a client too old to say its version is still told to update")
}
