import CryptoKit
import Foundation

/// Encrypts everything that crosses the link once the handshake has finished.
///
/// The handshake authenticated the peer but left the session itself in the
/// clear: contacts, call history, notification text, clipboard contents and the
/// screen all travelled as plaintext over the LAN, readable by anyone on the
/// same Wi-Fi without attacking anything. This closes that.
///
/// Keys are derived from the pairing secret the two devices already share — no
/// new trust — but over both handshake nonces, so keys never repeat across
/// connections. Each direction gets its own key, which is what lets both ends
/// number their frames from zero without ever colliding on a nonce.
///
/// Must stay byte-compatible with SessionCrypto.kt on the phone.
final class SessionCrypto {
    private let sendKey: SymmetricKey      // mac -> phone
    private let receiveKey: SymmetricKey   // phone -> mac
    private var sendCounter: UInt64 = 0
    /// Highest counter accepted; anything at or below it is a replay.
    private var lastReceived: Int64 = -1

    static let version: UInt8 = 1
    /// A UTF-8 JSON message — everything the two ends say to each other.
    static let kindJSON: UInt8 = 1
    /// A JPEG screen-mirror frame.
    static let kindFrame: UInt8 = 2
    /// A slice of a file in flight. The payload carries its own small header —
    /// a 4-byte transfer id and an 8-byte offset — so chunks can be written
    /// straight to the right place without buffering the whole file.
    static let kindFile: UInt8 = 3

    private static let header = 14

    init(secret: String, macNonce: String, phoneNonce: String) {
        let salt = Data((macNonce + phoneNonce).utf8)
        let ikm = SymmetricKey(data: Data(secret.utf8))
        sendKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt,
            info: Data("tethr/v1 mac->phone".utf8), outputByteCount: 32)
        receiveKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt,
            info: Data("tethr/v1 phone->mac".utf8), outputByteCount: 32)
    }

    /// Wraps `payload` into a self-describing encrypted frame.
    func seal(kind: UInt8, payload: Data) -> Data? {
        let counter = sendCounter
        sendCounter += 1
        var head = Data([Self.version, kind])
        head.append(Data(repeating: 0, count: 4))
        head.append(withUnsafeBytes(of: counter.bigEndian) { Data($0) })
        guard let nonce = try? AES.GCM.Nonce(data: head.subdata(in: 2..<Self.header)),
              // The header travels in the clear but is authenticated, so the
              // version, kind and counter cannot be tampered with in flight.
              let box = try? AES.GCM.seal(payload, using: sendKey, nonce: nonce,
                                          authenticating: head)
        else { return nil }
        return head + box.ciphertext + box.tag
    }

    /// Unwraps a frame, or nil if it is malformed, forged, or a replay.
    func open(_ frame: Data) -> (kind: UInt8, payload: Data)? {
        guard frame.count >= Self.header + 16, frame[frame.startIndex] == Self.version else { return nil }
        let kind = frame[frame.startIndex + 1]
        let nonceData = frame.subdata(in: (frame.startIndex + 2)..<(frame.startIndex + Self.header))
        let counter = nonceData.subdata(in: 4..<12).withUnsafeBytes {
            Int64(bigEndian: $0.loadUnaligned(as: Int64.self))
        }
        // Strictly increasing: a frame captured off the wire cannot be pushed
        // back in later, even though it would otherwise decrypt perfectly.
        guard counter > lastReceived else { return nil }

        let body = frame.subdata(in: (frame.startIndex + Self.header)..<frame.endIndex)
        let tagStart = body.count - 16
        guard tagStart >= 0,
              let nonce = try? AES.GCM.Nonce(data: nonceData),
              let box = try? AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: body.subdata(in: 0..<tagStart),
                tag: body.subdata(in: tagStart..<body.count)),
              let plain = try? AES.GCM.open(
                box, using: receiveKey,
                authenticating: frame.subdata(in: frame.startIndex..<(frame.startIndex + Self.header)))
        else { return nil }

        lastReceived = counter
        return (kind, plain)
    }
}
