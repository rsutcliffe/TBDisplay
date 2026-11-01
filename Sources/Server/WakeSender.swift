// Wakes the sleeping iMac. The iMac runs no TBDisplay while it sleeps, so the MacBook does it: when the iMac connects,
// its Mac address is read from the neighbour table and saved; later a Wake-on-LAN magic packet is broadcast on the
// interface it used. The iMac needs "Wake for network access" switched on. Whether the packet reaches a sleeping
// iMac over a given cable is not something this code can know, so every wake and its outcome goes into the log.

import AppKit
import Darwin

final class WakeSender {
    static let shared = WakeSender()

    /// What the menu shows under the Wake item.
    private(set) var lastResult: String?
    var state: ServerState?                      // set at start; tells whether an iMac is connected

    private var watching = false

    var savedMAC: String? { Prefs.defaults.string(forKey: Prefs.wakeMAC) }
    var automatic: Bool {
        get { Prefs.defaults.object(forKey: Prefs.wakeAutomatically) as? Bool ?? true }
        set { Prefs.defaults.set(newValue, forKey: Prefs.wakeAutomatically) }
    }
    private var iMacConnected: Bool { state?.stats.connected ?? false }

    /// At launch and after this Mac wakes: wake the iMac too, unless it is already connected.
    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.wakeAutomatically(after: 5, reason: "this MacBook woke up")      // the cable link needs a few seconds to come back
        }
        wakeAutomatically(after: 2, reason: "TBDisplay started")
    }

    private func wakeAutomatically(after seconds: Double, reason: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            guard automatic, savedMAC != nil, !iMacConnected else { return }
            wake(reason: reason)
        }
    }

    /// Called when an iMac has proved it holds the key: remember its Mac address. Reading the table runs two short
    /// system tools, so it is done off the main thread.
    func learn(address: String, interface: String?) {
        DispatchQueue.global().async {
            let found = ["/usr/sbin/ndp", "/usr/sbin/arp"].lazy.compactMap { tool -> (mac: String, interface: String?)? in
                guard let output = WakeSender.run(tool, ["-an"]), let mac = WakeOnLan.macInNeighbourTable(output, address: address) else { return nil }
                return (mac, WakeOnLan.interfaceInNeighbourTable(output, address: address))
            }.first
            DispatchQueue.main.async {
                guard let (mac, tableInterface) = found else { log("Could not read the iMac's Mac address for \(address), so it cannot be woken from here."); return }
                let interface = tableInterface ?? interface
                if Prefs.defaults.string(forKey: Prefs.wakeMAC) != mac || Prefs.defaults.string(forKey: Prefs.wakeInterface) != interface {
                    log("Saved the iMac's Mac address \(mac) on \(interface ?? "an unknown interface") for waking it.")
                }
                Prefs.defaults.set(mac, forKey: Prefs.wakeMAC)
                if let interface { Prefs.defaults.set(interface, forKey: Prefs.wakeInterface) }
            }
        }
    }

    /// Sends the magic packet, then watches for the iMac connecting so the log says whether the wake worked.
    func wake(reason: String) {
        guard let text = savedMAC, let mac = WakeOnLan.parseMAC(text), let packet = WakeOnLan.magicPacket(mac: mac) else {
            lastResult = "No iMac has connected yet, so there is nothing to wake."
            return
        }
        let interface = Prefs.defaults.string(forKey: Prefs.wakeInterface)
        guard WakeSender.broadcast(packet, interface: interface) else {
            lastResult = "Could not send the wake packet."
            log("Could not send the wake packet to \(text) on \(interface ?? "any interface").")
            return
        }
        log("Sent a wake packet to \(text) on \(interface ?? "any interface") (\(reason)).")
        lastResult = "Wake sent. Waiting for the iMac…"
        watchForIMac(since: Date())
    }

    private func watchForIMac(since start: Date) {
        guard !watching else { return }
        watching = true
        func poll() {
            let seconds = Int(Date().timeIntervalSince(start))
            if iMacConnected {
                watching = false
                lastResult = "The iMac connected \(seconds) s after the wake."
                log(lastResult!)
            } else if seconds >= 60 {
                watching = false
                lastResult = "No answer 60 s after the wake. Check Wake for network access on the iMac, and try Ethernet or Wi-Fi."
                log(lastResult!)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { poll() }
            }
        }
        poll()
    }

    // MARK: - Plumbing

    private static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// UDP broadcast to port 9, three times, out of one interface when it is named.
    private static func broadcast(_ packet: Data, interface: String?) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        if let interface, if_nametoindex(interface) != 0 {
            var index = if_nametoindex(interface)
            setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(9).bigEndian
        address.sin_addr.s_addr = INADDR_BROADCAST.bigEndian
        var sent = false
        for attempt in 0..<3 {
            if attempt > 0 { usleep(300_000) }
            let result = packet.withUnsafeBytes { bytes in
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if result == packet.count { sent = true }
        }
        return sent
    }
}
