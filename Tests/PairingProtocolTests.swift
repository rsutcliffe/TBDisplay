// The pairing handshake: both Macs show the same six digits, and nobody in the middle can make them match.

import CryptoKit
import Foundation
#if canImport(TBCore)
@testable import TBCore
#endif

func runPairingProtocolTests() {
    func randomNonce() -> Data { Data((0..<16).map { _ in UInt8.random(in: 0...255) }) }
    let secret = Data((0..<32).map { UInt8($0 &* 7 &+ 3) })       // stands in for the MacBook's pairing key

    /// An honest run. Returns what each side saw.
    func honestRun() -> (initiatorCode: String, responderCode: String, sealed: Data, opened: Data)? {
        var responder = PairingResponder(pairingKey: secret, privateKey: .init(), nonce: randomNonce())
        var initiator = PairingInitiator(privateKey: .init(), nonce: randomNonce())
        guard let response = try? responder.receiveCommit(initiator.commitMessage()),
              let step = try? initiator.receiveResponse(response),
              let responderCode = try? responder.receiveReveal(step.reveal),
              let sealed = try? responder.sealedKey(),
              let opened = try? initiator.openKey(sealed) else { return nil }
        return (step.code, responderCode, sealed, opened)
    }

    /// The same bytes with the last bit flipped (safe on empty data, so a stub fails the test instead of crashing it).
    func flippedLast(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data([0x01]) }
        var copy = data; copy[copy.count - 1] ^= 0x01; return copy
    }

    func throwsError(_ expected: PairingError, _ block: () throws -> Void) -> Bool {
        do { try block(); return false } catch { return (error as? PairingError) == expected }
    }

    // The code itself
    check(PairingCode.code(from: Data([0, 0, 0, 7, 9, 9])) == "000007", "a small number is padded to six digits")
    check(PairingCode.code(from: Data([0xFF, 0xFF, 0xFF, 0xFF, 1])) == "967295", "the code is the first four bytes modulo one million")

    // An honest run
    if let run = honestRun() {
        check(run.initiatorCode == run.responderCode, "both Macs show the same code")
        check(run.initiatorCode.count == 6 && run.initiatorCode.allSatisfy(\.isNumber), "the code is six digits")
        check(run.opened == secret, "the iMac receives exactly the MacBook's pairing key")
        check(run.sealed.count == 60, "the sealed key is a 12 byte nonce, 32 bytes of key and a 16 byte tag")
        check(run.sealed.range(of: secret) == nil, "the pairing key does not appear in the clear")
    } else {
        check(false, "an honest run completes")
    }
    let codes = Set((0..<50).compactMap { _ in honestRun()?.initiatorCode })
    check(codes.count > 40, "different sessions give different codes")

    // A man in the middle runs a pairing with each side and cannot make the codes match
    var mismatches = 0
    for _ in 0..<20 {
        var realResponder = PairingResponder(pairingKey: secret, privateKey: .init(), nonce: randomNonce())
        var realInitiator = PairingInitiator(privateKey: .init(), nonce: randomNonce())
        var fakeResponder = PairingResponder(pairingKey: Data(count: 32), privateKey: .init(), nonce: randomNonce())   // faces the real iMac
        var fakeInitiator = PairingInitiator(privateKey: .init(), nonce: randomNonce())                                // faces the real MacBook
        guard let toIMac = try? fakeResponder.receiveCommit(realInitiator.commitMessage()),
              let imacStep = try? realInitiator.receiveResponse(toIMac),
              let toMac = try? realResponder.receiveCommit(fakeInitiator.commitMessage()),
              let fakeStep = try? fakeInitiator.receiveResponse(toMac),
              let imacSees = Optional(imacStep.code),
              let macSees = try? realResponder.receiveReveal(fakeStep.reveal) else { continue }
        if imacSees != macSees { mismatches += 1 }
    }
    check(mismatches == 20, "a man in the middle ends up with different codes on the two screens")

    // A key sealed for one session cannot be opened in another
    if let a = honestRun() {
        var other = PairingInitiator(privateKey: .init(), nonce: randomNonce())
        var responder = PairingResponder(pairingKey: secret, privateKey: .init(), nonce: randomNonce())
        if let reply = try? responder.receiveCommit(other.commitMessage()), let step = try? other.receiveResponse(reply) {
            _ = try? responder.receiveReveal(step.reveal)
        }
        check(throwsError(.decryptFailed) { _ = try other.openKey(a.sealed) }, "a sealed key from another session cannot be opened")
    }
    do {
        var responder = PairingResponder(pairingKey: secret, privateKey: .init(), nonce: randomNonce())
        var initiator = PairingInitiator(privateKey: .init(), nonce: randomNonce())
        if let reply = try? responder.receiveCommit(initiator.commitMessage()), let step = try? initiator.receiveResponse(reply) {
            _ = try? responder.receiveReveal(step.reveal)
            if let sealed = try? responder.sealedKey() {
                check(throwsError(.decryptFailed) { _ = try initiator.openKey(flippedLast(sealed)) }, "a tampered sealed key is refused")
            } else { check(false, "a sealed key is available after the reveal") }
        } else { check(false, "the tamper test session runs") }
    }

    // The commitment: the iMac cannot change its key after seeing the MacBook's
    do {
        var responder = PairingResponder(pairingKey: secret, privateKey: .init(), nonce: randomNonce())
        let honest = PairingInitiator(privateKey: .init(), nonce: randomNonce())
        _ = try? responder.receiveCommit(honest.commitMessage())
        var swapped = PairingInitiator(privateKey: .init(), nonce: randomNonce())
        var spare = PairingResponder(pairingKey: secret, privateKey: .init(), nonce: randomNonce())
        if let reply = try? spare.receiveCommit(swapped.commitMessage()), let step = try? swapped.receiveResponse(reply) {
            check(throwsError(.commitMismatch) { _ = try responder.receiveReveal(step.reveal) }, "a reveal that does not match the commit is refused")
        } else { check(false, "the swapped initiator can run") }
    }
    do {
        var responder = PairingResponder(pairingKey: secret, privateKey: .init(), nonce: randomNonce())
        var initiator = PairingInitiator(privateKey: .init(), nonce: randomNonce())
        if let reply = try? responder.receiveCommit(initiator.commitMessage()), let step = try? initiator.receiveResponse(reply) {
            check(throwsError(.commitMismatch) { _ = try responder.receiveReveal(flippedLast(step.reveal)) }, "changing only the nonce is also caught")
        } else { check(false, "the initiator can run") }
    }

    // Order and size
    do {
        var responder = PairingResponder(pairingKey: secret, privateKey: .init(), nonce: randomNonce())
        check(throwsError(.outOfOrder) { _ = try responder.receiveReveal(Data(count: 48)) }, "a reveal before a commit is refused")
        check(throwsError(.outOfOrder) { _ = try responder.sealedKey() }, "no key is sealed before the reveal")
        check(throwsError(.badLength) { _ = try responder.receiveCommit(Data(count: 31)) }, "a short commit is refused")
        let initiator = PairingInitiator(privateKey: .init(), nonce: randomNonce())
        _ = try? responder.receiveCommit(initiator.commitMessage())
        check(throwsError(.alreadyUsed) { _ = try responder.receiveCommit(initiator.commitMessage()) }, "a second commit in one session is refused")
        check(throwsError(.badLength) { _ = try responder.receiveReveal(Data(count: 47)) }, "a short reveal is refused")
    }
    do {
        // Finding 1 of the review: only one answer per commit, or the commitment binds nothing
        var once = PairingInitiator(privateKey: .init(), nonce: randomNonce())
        var responderA = PairingResponder(pairingKey: secret, privateKey: .init(), nonce: randomNonce())
        var responderB = PairingResponder(pairingKey: secret, privateKey: .init(), nonce: randomNonce())
        let commit = once.commitMessage()
        if let a = try? responderA.receiveCommit(commit), let b = try? responderB.receiveCommit(commit) {
            _ = try? once.receiveResponse(a)
            check(throwsError(.alreadyUsed) { _ = try once.receiveResponse(b) }, "a second answer to the same commit is refused")
        } else { check(false, "two responders answer one commit") }
    }
    do {
        var initiator = PairingInitiator(privateKey: .init(), nonce: randomNonce())
        check(throwsError(.badLength) { _ = try initiator.receiveResponse(Data(count: 47)) }, "a short response is refused")
        check(throwsError(.outOfOrder) { _ = try initiator.openKey(Data(count: 60)) }, "the iMac cannot open a key before the exchange")
    }
}
