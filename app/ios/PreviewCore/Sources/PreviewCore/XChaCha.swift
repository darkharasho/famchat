// XChaCha20-Poly1305 (draft-irtf-cfrg-xchacha-03) on top of CryptoKit's ChaCha20-Poly1305.
// CryptoKit has no HChaCha20, so it is written out here.
import CryptoKit
import Foundation

public enum PreviewError: Error { case malformed, badSignature, decrypt }

public enum XChaCha {
    /// HChaCha20: 20 ChaCha rounds over (constants, key, 16-byte nonce) with no final addition.
    /// Returns words 0-3 and 12-15 of the state, little-endian (32 bytes).
    public static func hChaCha20(key: [UInt8], nonce16: [UInt8]) -> [UInt8] {
        precondition(key.count == 32 && nonce16.count == 16)
        func word(_ b: [UInt8], _ i: Int) -> UInt32 {
            UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
        }
        var s: [UInt32] = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]
        for i in 0..<8 { s.append(word(key, i * 4)) }
        for i in 0..<4 { s.append(word(nonce16, i * 4)) }

        func rotl(_ v: UInt32, _ n: UInt32) -> UInt32 { (v << n) | (v >> (32 - n)) }
        func qr(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            s[a] = s[a] &+ s[b]; s[d] = rotl(s[d] ^ s[a], 16)
            s[c] = s[c] &+ s[d]; s[b] = rotl(s[b] ^ s[c], 12)
            s[a] = s[a] &+ s[b]; s[d] = rotl(s[d] ^ s[a], 8)
            s[c] = s[c] &+ s[d]; s[b] = rotl(s[b] ^ s[c], 7)
        }
        for _ in 0..<10 {
            qr(0, 4, 8, 12); qr(1, 5, 9, 13); qr(2, 6, 10, 14); qr(3, 7, 11, 15)
            qr(0, 5, 10, 15); qr(1, 6, 11, 12); qr(2, 7, 8, 13); qr(3, 4, 9, 14)
        }
        var out: [UInt8] = []
        for w in [s[0], s[1], s[2], s[3], s[12], s[13], s[14], s[15]] {
            out += [UInt8(w & 0xff), UInt8((w >> 8) & 0xff), UInt8((w >> 16) & 0xff), UInt8(w >> 24)]
        }
        return out
    }

    /// Opens `sealed` (ciphertext followed by the 16-byte tag). Throws `.malformed` for bad
    /// lengths and `.decrypt` when authentication fails.
    public static func open(key: Data, nonce: Data, sealed: Data, aad: Data) throws -> Data {
        guard key.count == 32, nonce.count == 24, sealed.count >= 16 else { throw PreviewError.malformed }
        let n = [UInt8](nonce)
        let subkey = hChaCha20(key: [UInt8](key), nonce16: Array(n[0..<16]))
        let s = [UInt8](sealed)
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: Data([0, 0, 0, 0] + n[16..<24])),
                ciphertext: Data(s[0..<(s.count - 16)]),
                tag: Data(s[(s.count - 16)...]))
            return try ChaChaPoly.open(box, using: SymmetricKey(data: subkey), authenticating: aad)
        } catch {
            throw PreviewError.decrypt
        }
    }
}
