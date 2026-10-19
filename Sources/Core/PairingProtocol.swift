// Pairing two Macs without copying a file. Both screens show the same six digits, and the person checks that
// they match. The MacBook then sends the pairing key, sealed so only this session can open it.
//
// The steps (X25519 key agreement, SHA-256 and ChaCha20-Poly1305 from Apple's CryptoKit, nothing hand-made):
//   1. iMac    -> MacBook   commit  = SHA256(label | pubC | nonceC)        the iMac commits before it sees anything
//   2. MacBook -> iMac      pubS | nonceS
//   3. iMac    -> MacBook   pubC | nonceC                                  the MacBook checks it against the commit
//   4. Both compute code = first four bytes of SHA256(label | pubC | nonceC | pubS | nonceS), modulo one million.
//   5. After the person confirms on the MacBook: MacBook -> iMac   the pairing key sealed with ChaCha20-Poly1305,
//      under a key from HKDF over the shared secret, salted with that same hash.
// The commitment is what makes a six digit code safe: a man in the middle must choose his key before he knows
// the other side's, so he has a one in a million chance per attempt of making the two screens agree.

import CryptoKit
import Foundation

enum PairingError: Error, Equatable { case badLength, commitMismatch, outOfOrder, decryptFailed, alreadyUsed }

private let label = Data("tbdisplay-pair-v1".utf8)

private func randomNonce() -> Data { Data((0..<16).map { _ in UInt8.random(in: 0...255) }) }
private func hash(_ parts: Data...) -> Data { Data(SHA256.hash(data: parts.reduce(Data(), +))) }

private func sessionKey(shared: SharedSecret, transcript: Data) -> SymmetricKey {
    shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript,
                                   sharedInfo: Data("tbdisplay-pair-key".utf8), outputByteCount: 32)
}

enum PairingCode {
    /// Six digits from a hash: the first four bytes as a number, modulo one million, padded with zeros.
    static func code(from digest: Data) -> String {
        let bytes = Array(digest.prefix(4))
        let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06d", value % 1_000_000)
    }
}

/// The MacBook's side.
struct PairingResponder {
    private enum State { case fresh, committed, revealed, failed }

    private let pairingKey: Data
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let nonce: Data
    private var state = State.fresh
    private var commit = Data()
    private var key: SymmetricKey?

    init(pairingKey: Data, privateKey: Curve25519.KeyAgreement.PrivateKey = .init(), nonce: Data = randomNonce()) {
        self.pairingKey = pairingKey
        self.privateKey = privateKey
        self.nonce = nonce
    }

    /// Step 2. Takes the iMac's commit, answers with this side's public key and nonce.
    mutating func receiveCommit(_ commit: Data) throws -> Data {
        guard state == .fresh else { throw PairingError.alreadyUsed }
        guard commit.count == 32 else { throw PairingError.badLength }
        self.commit = commit
        state = .committed
        return privateKey.publicKey.rawRepresentation + nonce
    }

    /// Step 4. Checks the reveal against the commit and returns the code to show.
    mutating func receiveReveal(_ reveal: Data) throws -> String {
        guard state == .committed else { throw PairingError.outOfOrder }
        guard reveal.count == 48 else { throw PairingError.badLength }
        let pubC = reveal.prefix(32), nonceC = reveal.suffix(16)
        guard hash(label, Data(pubC), Data(nonceC)) == commit else { state = .failed; throw PairingError.commitMismatch }
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubC),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: peer) else { state = .failed; throw PairingError.badLength }
        let transcript = hash(label, Data(pubC), Data(nonceC), privateKey.publicKey.rawRepresentation, nonce)
        key = sessionKey(shared: shared, transcript: transcript)
        state = .revealed
        return PairingCode.code(from: transcript)
    }

    /// Step 5. Only after the person has confirmed the codes match.
    func sealedKey() throws -> Data {
        guard state == .revealed, let key else { throw PairingError.outOfOrder }
        guard let box = try? ChaChaPoly.seal(pairingKey, using: key) else { throw PairingError.decryptFailed }
        return box.combined
    }
}

/// The iMac's side.
struct PairingInitiator {
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let nonce: Data
    private var key: SymmetricKey?

    init(privateKey: Curve25519.KeyAgreement.PrivateKey = .init(), nonce: Data = randomNonce()) {
        self.privateKey = privateKey
        self.nonce = nonce
    }

    /// Step 1.
    func commitMessage() -> Data { hash(label, privateKey.publicKey.rawRepresentation, nonce) }

    /// Step 3. Takes the MacBook's answer, returns the reveal to send and the code to show.
    mutating func receiveResponse(_ response: Data) throws -> (reveal: Data, code: String) {
        guard key == nil else { throw PairingError.alreadyUsed }      // one answer per commit, or the commitment binds nothing
        guard response.count == 48 else { throw PairingError.badLength }
        let pubS = Data(response.prefix(32)), nonceS = Data(response.suffix(16))
        guard let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubS),
              let shared = try? privateKey.sharedSecretFromKeyAgreement(with: peer) else { throw PairingError.badLength }
        let transcript = hash(label, privateKey.publicKey.rawRepresentation, nonce, pubS, nonceS)
        key = sessionKey(shared: shared, transcript: transcript)
        return (privateKey.publicKey.rawRepresentation + nonce, PairingCode.code(from: transcript))
    }

    /// Step 5. Opens the sealed pairing key.
    func openKey(_ sealed: Data) throws -> Data {
        guard let key else { throw PairingError.outOfOrder }
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed),
              let opened = try? ChaChaPoly.open(box, using: key) else { throw PairingError.decryptFailed }
        return opened
    }
}
