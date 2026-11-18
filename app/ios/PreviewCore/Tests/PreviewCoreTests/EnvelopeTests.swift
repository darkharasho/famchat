import XCTest
import CryptoKit
@testable import PreviewCore

final class EnvelopeTests: XCTestCase {
    func b64(_ d: [UInt8]) -> String {
        Data(d).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func json(v: String = "1", nonce: [UInt8] = [UInt8](repeating: 1, count: 24), nonceStr: String? = nil) -> Data {
        let n = nonceStr ?? b64(nonce)
        return Data("""
        {"v":\(v),"epoch":3,"nonce":"\(n)","ct":"\(b64([UInt8](repeating: 2, count: 20)))","sig":"\(b64([UInt8](repeating: 3, count: 64)))"}
        """.utf8)
    }

    func assertMalformed(_ f: @autoclosure () throws -> Any, line: UInt = #line) {
        XCTAssertThrowsError(try f(), line: line) { XCTAssertEqual($0 as? PreviewError, .malformed, line: line) }
    }

    func testAadBytes() throws {
        let aad = try Envelope.aad(v: 1, chatId: "C", epoch: 258, messageId: "M", senderDeviceId: "D")
        XCTAssertEqual([UInt8](aad), Array("famchat-envelope-v1".utf8) + [1, 0, 1, 0x43, 0, 0, 1, 2, 0, 1, 0x4d, 0, 1, 0x44])
    }

    func testParsesValid() throws {
        let e = try Envelope(json: json())
        XCTAssertEqual(e.v, 1)
        XCTAssertEqual(e.epoch, 3)
        XCTAssertEqual(e.nonce.count, 24)
        XCTAssertEqual(e.ct.count, 20)
        XCTAssertEqual(e.sig.count, 64)
    }

    func testRejectsShortNonce() {
        assertMalformed(try Envelope(json: json(nonce: [UInt8](repeating: 1, count: 23))))
    }

    func testRejectsPaddedBase64() {
        assertMalformed(try Envelope(json: json(nonceStr: "AAAA=")))
    }

    func testRejectsBoolV() {
        assertMalformed(try Envelope(json: json(v: "true")))
    }

    func testRejectsFractionalV() {
        assertMalformed(try Envelope(json: json(v: "1.5")))
    }

    func testRejectsVersion2() throws {
        let e = try Envelope(json: json(v: "2"))
        XCTAssertThrowsError(
            try e.open(chatKey: Data(count: 32), chatId: "C", messageId: "M", senderDeviceId: "D",
                       senderSignPub: Data(count: 32))
        ) { XCTAssertEqual($0 as? PreviewError, .malformed) }
    }

    func testB64urlLenMod4Is1() {
        XCTAssertNil(b64urlDecode("A"))
    }

    func testBadSignatureThrows() throws {
        let e = try Envelope(json: json())
        let pub = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        XCTAssertThrowsError(
            try e.open(chatKey: Data(count: 32), chatId: "C", messageId: "M", senderDeviceId: "D", senderSignPub: pub)
        ) { XCTAssertEqual($0 as? PreviewError, .badSignature) }
    }

    func testRoundTripSignedEnvelope() throws {
        // Build an envelope the way the Dart client does, then open it.
        let chatKey = Data((0..<32).map { UInt8($0) })
        let nonce = Data((0..<24).map { UInt8(100 + $0) })
        let aad = try Envelope.aad(v: 1, chatId: "C", epoch: 3, messageId: "M", senderDeviceId: "D")
        let subkey = XChaCha.hChaCha20(key: [UInt8](chatKey), nonce16: [UInt8](nonce[0..<16]))
        let box = try ChaChaPoly.seal(Data("hello".utf8), using: SymmetricKey(data: subkey),
                                      nonce: ChaChaPoly.Nonce(data: Data([0, 0, 0, 0]) + nonce[16..<24]),
                                      authenticating: aad)
        let ct = box.ciphertext + box.tag
        let signer = Curve25519.Signing.PrivateKey()
        let sig = try signer.signature(for: aad + nonce + ct)
        let j = Data("""
        {"v":1,"epoch":3,"nonce":"\(b64([UInt8](nonce)))","ct":"\(b64([UInt8](ct)))","sig":"\(b64([UInt8](sig)))"}
        """.utf8)
        let e = try Envelope(json: j)
        let pt = try e.open(chatKey: chatKey, chatId: "C", messageId: "M", senderDeviceId: "D",
                            senderSignPub: signer.publicKey.rawRepresentation)
        XCTAssertEqual(String(decoding: pt, as: UTF8.self), "hello")
        XCTAssertThrowsError(
            try e.open(chatKey: chatKey, chatId: "C", messageId: "other", senderDeviceId: "D",
                       senderSignPub: signer.publicKey.rawRepresentation)
        ) { XCTAssertEqual($0 as? PreviewError, .badSignature) }
    }
}
