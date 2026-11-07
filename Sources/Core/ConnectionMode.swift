// Which kind of connection the MacBook and the iMac use to reach each other, chosen from a menu on both Macs.
// This file only decides. The apps read the interface a connection is on and ask it.

import Foundation

enum ConnectionMode: String, CaseIterable, Equatable {
    case thunderbolt, wifi, ethernet

    var title: String {
        switch self {
        case .thunderbolt: return "Thunderbolt"
        case .wifi: return "Wi-Fi"
        case .ethernet: return "Ethernet"
        }
    }

    /// Thunderbolt is the Thunderbolt Bridge by name. The others go by what macOS says the interface is,
    /// so a USB network link between the Macs counts as Ethernet.
    func allows(interfaceName: String, kind: InterfaceKind) -> Bool {
        switch self {
        case .thunderbolt: return interfaceName == defaultInterfaceName
        case .wifi: return kind == .wifi
        case .ethernet: return kind == .wired && interfaceName != defaultInterfaceName
        }
    }

    static func saved(from defaults: UserDefaults = Prefs.defaults) -> ConnectionMode {
        defaults.string(forKey: Prefs.connectionMode).flatMap(ConnectionMode.init(rawValue:)) ?? .thunderbolt
    }

    func save(to defaults: UserDefaults = Prefs.defaults) { defaults.set(rawValue, forKey: Prefs.connectionMode) }

    /// What the iMac is told when it arrives some other way than the mode this Mac accepts.
    var refusalNotice: String {
        "This MacBook accepts \(title) only. Change Connect over in its menu bar item, or move this iMac to \(title)."
    }
}

/// What a Mac accepts: the saved mode, or a command line override used by tests and by people who know the name.
enum InterfacePolicy: Equatable {
    case mode(ConnectionMode)
    case named(String)
    case any

    func allows(interfaceName: String, kind: InterfaceKind) -> Bool {
        switch self {
        case .mode(let mode): return mode.allows(interfaceName: interfaceName, kind: kind)
        case .named(let name): return interfaceName == name
        case .any: return true
        }
    }

    var refusalNotice: String {
        switch self {
        case .mode(let mode): return mode.refusalNotice
        case .named(let name): return "This MacBook accepts \(name) only."
        case .any: return ""
        }
    }

    var summary: String {
        switch self {
        case .mode(let mode): return "over \(mode.title)"
        case .named(let name): return "on \(name)"
        case .any: return "on any interface"
        }
    }
}
