// Waking a sleeping iMac: the magic packet, reading a Mac address, and finding the iMac in the neighbour table.

import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runWakeOnLanTests() {
    let mac: [UInt8] = [0x3c, 0x22, 0xfb, 0x01, 0x0a, 0xff]

    check(WakeOnLan.parseMAC("3c:22:fb:1:a:ff") == mac, "a Mac address with single digit parts is read")
    check(WakeOnLan.parseMAC("3C-22-FB-01-0A-FF") == mac, "capitals and dashes are read")
    check(WakeOnLan.parseMAC("3c:22:fb:01:0a") == nil, "five parts is not a Mac address")
    check(WakeOnLan.parseMAC("3c:22:fb:01:0a:gg") == nil, "non hex is not a Mac address")
    check(WakeOnLan.parseMAC("(incomplete)") == nil, "an incomplete entry is not a Mac address")
    check(WakeOnLan.format(mac) == "3c:22:fb:01:0a:ff", "a Mac address is written with two digits per part")

    let packet = WakeOnLan.magicPacket(mac: mac)
    check(packet?.count == 102, "the magic packet is 102 bytes")
    let bytes = Array(packet ?? Data())
    check(Array(bytes.prefix(6)) == [UInt8](repeating: 0xff, count: 6), "it starts with six 0xff bytes")
    check(Array(bytes.dropFirst(6)) == Array([[UInt8]](repeating: mac, count: 16).joined()), "then the Mac address sixteen times")
    check(WakeOnLan.magicPacket(mac: [1, 2, 3]) == nil, "a short Mac address makes no packet")

    let ndp = """
    Neighbor                        Linklayer Address  Netif Expire    St Flgs Prbs
    fe80::1c2a:3b4c:5d6e:7f80%bridge0 3c:22:fb:1:a:ff    bridge0 23h59m1s  S  R
    fe80::aaaa:bbbb:cccc:dddd%en0   (incomplete)        en0 expired   N
    """
    check(WakeOnLan.macInNeighbourTable(ndp, address: "fe80::1c2a:3b4c:5d6e:7f80") == "3c:22:fb:01:0a:ff", "ndp output gives the iMac's address")
    check(WakeOnLan.macInNeighbourTable(ndp, address: "FE80::1C2A:3B4C:5D6E:7F80") == "3c:22:fb:01:0a:ff", "address case does not matter")
    check(WakeOnLan.macInNeighbourTable(ndp, address: "fe80::aaaa:bbbb:cccc:dddd") == nil, "an incomplete entry gives nothing")
    check(WakeOnLan.macInNeighbourTable("fe80::5%en0  2:0:0:0:0:0  en0 permanent R", address: "fe80::5") == nil, "macOS's hidden address placeholder is not taken for the iMac")
    check(WakeOnLan.macInNeighbourTable(ndp, address: "fe80::9") == nil, "an unknown address gives nothing")
    check(WakeOnLan.interfaceInNeighbourTable(ndp, address: "fe80::1c2a:3b4c:5d6e:7f80") == "bridge0", "ndp output names the interface")

    let arp = """
    ? (169.254.10.2) at 3c:22:fb:1:a:ff on en5 ifscope [ethernet]
    ? (169.254.10.20) at 11:22:33:44:55:66 on en5 ifscope [ethernet]
    ? (169.254.10.9) at (incomplete) on en5 ifscope [ethernet]
    """
    check(WakeOnLan.macInNeighbourTable(arp, address: "169.254.10.2") == "3c:22:fb:01:0a:ff", "arp output gives the iMac's address")
    check(WakeOnLan.interfaceInNeighbourTable(arp, address: "169.254.10.2") == "en5", "arp output names the interface")
    check(WakeOnLan.macInNeighbourTable(arp, address: "169.254.10.20") == "11:22:33:44:55:66", "a longer address is not mixed up with a shorter one")
    check(WakeOnLan.macInNeighbourTable(arp, address: "169.254.10.9") == nil, "arp incomplete gives nothing")
}
