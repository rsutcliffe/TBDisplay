// Writes sleeping, waking and Thunderbolt Bridge changes into the log, each with a time, so the next time the cable
// link fails to come back the log shows what happened first. The wording and change detection are LinkWatch.

import AppKit
import Darwin

enum PowerLog {
    private static var watch = LinkWatch()          // touched on the main thread only
    private static var timer: DispatchSourceTimer?

    /// The bridge is up when it has an IPv4 address (macOS gives it one only while the cable link is active).
    /// NWPathMonitor does not list bridge0 as an available interface even when it works, so it is read directly.
    static func bridgeIsUp() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor?.pointee {
            if String(cString: entry.ifa_name) == defaultInterfaceName, let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                return true
            }
            cursor = entry.ifa_next
        }
        return false
    }

    static func start() {
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, PowerEvent)] = [
            (NSWorkspace.willSleepNotification, .willSleep), (NSWorkspace.didWakeNotification, .didWake),
            (NSWorkspace.screensDidSleepNotification, .displaysSlept), (NSWorkspace.screensDidWakeNotification, .displaysWoke),
        ]
        for (name, event) in events {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                log(event.text)
                if event == .didWake { log("Thunderbolt Bridge after waking: \(bridgeIsUp() ? "up" : "down").") }
            }
        }
        if let line = watch.update(bridgeUp: bridgeIsUp()) { log(line) }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { if let line = watch.update(bridgeUp: bridgeIsUp()) { log(line) } }
        timer.resume()
        self.timer = timer
    }
}
