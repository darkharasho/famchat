// Message envelope opening, mirroring app/lib/crypto/envelope.dart.
//   aad = "famchat-envelope-v1" | u8(v) | str(chatId) | u32(epoch) | str(messageId) | str(senderDeviceId)
//   sig = Ed25519(senderSignKey, aad | nonce | ct); ct = XChaCha20-Poly1305 ciphertext | 16-byte tag
import CryptoKit
import Foundation

/// Decodes base64url without padding; nil for anything else (same rules as Dart's `b64urlDecode`).
public func b64urlDecode(_ s: String) -> Data? {
    for u in s.unicodeScalars {
        let ok = (u >= "A" && u <= "Z") || (u >= "a" && u <= "z") || (u >= "0" && u <= "9") || u == "_" || u == "-"
        if !ok { return nil }
    }
    if s.count % 4 == 1 { return nil }
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return Data(base64Encoded: t)
}

public struct Envelope {
    public let v: Int
    public let epoch: UInt32
    public let nonce: Data
    public let ct: Data
    public let sig: Data

    private struct Raw: Decodable {
        let v: Int
        let epoch: UInt32
        let nonce: String
        let ct: String
        let sig: String
    }

    /// Throws `.malformed` for bad JSON, mistyped fields, bad base64, a nonce that isn't 24 bytes,
    /// ct shorter than the tag or a signature that isn't 64 bytes.
    public init(json: Data) throws {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: json),
              raw.v >= 0, raw.v <= 0xff,
              let nonce = b64urlDecode(raw.nonce), nonce.count == 24,
              let ct = b64urlDecode(raw.ct), ct.count >= 16,
              let sig = b64urlDecode(raw.sig), sig.count == 64
        else { throw PreviewError.malformed }
        self.v = raw.v
        self.epoch = raw.epoch
        self.nonce = nonce
        self.ct = ct
        self.sig = sig
    }

    public static func aad(v: Int, chatId: String, epoch: UInt32, messageId: String,
                           senderDeviceId: String) throws -> Data {
        guard v >= 0, v <= 0xff else { throw PreviewError.malformed }
        func str(_ s: String) throws -> [UInt8] {
            let b = Array(s.utf8)
            guard b.count <= 0xffff else { throw PreviewError.malformed }
            return [UInt8(b.count >> 8), UInt8(b.count & 0xff)] + b
        }
        var out = Array("famchat-envelope-v1".utf8)
        out.append(UInt8(v))
        out += try str(chatId)
        out += [UInt8(epoch >> 24), UInt8((epoch >> 16) & 0xff), UInt8((epoch >> 8) & 0xff), UInt8(epoch & 0xff)]
        out += try str(messageId)
        out += try str(senderDeviceId)
        return Data(out)
    }

    /// Verifies the sender's signature, then decrypts. The caller picks `chatKey` by `epoch`.
    public func open(chatKey: Data, chatId: String, messageId: String, senderDeviceId: String,
                     senderSignPub: Data) throws -> Data {
        guard v == 1 else { throw PreviewError.malformed }
        guard nonce.count == 24, ct.count >= 16, sig.count == 64, senderSignPub.count == 32 else {
            throw PreviewError.malformed
        }
        let aad = try Envelope.aad(v: v, chatId: chatId, epoch: epoch, messageId: messageId,
                                   senderDeviceId: senderDeviceId)
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: senderSignPub),
              pub.isValidSignature(sig, for: aad + nonce + ct)
        else { throw PreviewError.badSignature }
        return try XChaCha.open(key: chatKey, nonce: nonce, sealed: ct, aad: aad)
    }
}
