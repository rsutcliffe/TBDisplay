// Which Mac to update when the two apps do not match.

enum VersionCheck {
    /// The sentence the MacBook sends to the iMac when it refuses a client because of its version.
    static func refusalNotice(clientProtocol: UInt32, clientApp: String, serverProtocol: UInt32, serverApp: String) -> String {
        if clientApp.isEmpty {
            return "This iMac has an older TBDisplay than the MacBook (\(serverApp)). Update TBDisplay on the iMac."
        }
        let target = clientProtocol < serverProtocol ? "iMac" : "MacBook"
        return "This iMac has TBDisplay \(clientApp) and the MacBook has \(serverApp). Update TBDisplay on the \(target)."
    }
}
