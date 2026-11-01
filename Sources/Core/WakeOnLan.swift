// Waking a sleeping iMac from the MacBook. This file holds the parts with no network in them: the magic packet,
// reading a Mac address, and finding the iMac's address in the output of arp and ndp. The sending is in Sources/Server.

import Foundation

enum WakeOnLan {
    /// "3c:22:fb:1:a:ff" (arp and ndp drop leading zeros) or "3C-22-FB-01-0A-FF". Six parts of one or two hex digits.
    static func parseMAC(_ text: String) -> [UInt8]? {
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard (1...2).contains(part.count), let value = UInt8(part, radix: 16) else { return nil }
            bytes.append(value)
        }
        return bytes
    }

    static func format(_ mac: [UInt8]) -> String { mac.map { String(format: "%02x", $0) }.joined(separator: ":") }

    /// Six 0xff bytes, then the Mac address sixteen times.
    static func magicPacket(mac: [UInt8]) -> Data? {
        guard mac.count == 6 else { return nil }
        return Data([UInt8](repeating: 0xff, count: 6) + Array((0..<16).map { _ in mac }.joined()))
    }

    /// The Mac address `arp -an` or `ndp -an` lists for this IP address, as text. An incomplete entry gives nil.
    static func macInNeighbourTable(_ output: String, address: String) -> String? { neighbour(output, address: address)?.mac }

    /// The interface that entry is on ("bridge0", "en5"). NWPathMonitor does not always name the Thunderbolt Bridge,
    /// so the table is the dependable place to read it.
    static func interfaceInNeighbourTable(_ output: String, address: String) -> String? { neighbour(output, address: address)?.interface }

    private static func neighbour(_ output: String, address: String) -> (mac: String, interface: String?)? {
        let wanted = address.lowercased()
        for line in output.split(separator: "\n") {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let at = tokens.firstIndex(where: { token in
                let bare = token.trimmingCharacters(in: CharacterSet(charactersIn: "()")).lowercased()
                return bare.split(separator: "%", maxSplits: 1).first.map(String.init) == wanted
            }) else { continue }
            // macOS shows 02:00:00:00:00:00 in place of a real address to a program that may not read the local network
            guard let m = tokens[(at + 1)...].firstIndex(where: { parseMAC($0) != nil }), let mac = parseMAC(tokens[m]),
                  mac != [2, 0, 0, 0, 0, 0] else { continue }
            var rest = tokens[(m + 1)...]
            if rest.first == "on" { rest = rest.dropFirst() }          // arp: "at <mac> on en5"; ndp: "<mac> en5"
            return (format(mac), rest.first)
        }
        return nil
    }
}
