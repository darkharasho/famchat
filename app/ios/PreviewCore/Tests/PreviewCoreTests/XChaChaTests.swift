import XCTest
@testable import PreviewCore

func hex(_ s: String) -> [UInt8] {
    let c = Array(s.filter { !$0.isWhitespace })
    return stride(from: 0, to: c.count, by: 2).map { UInt8(String(c[$0...$0 + 1]), radix: 16)! }
}

final class XChaChaTests: XCTestCase {
    // draft-irtf-cfrg-xchacha-03 appendix A.3.1
    let key = hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
    let nonce = hex("404142434445464748494a4b4c4d4e4f5051525354555657")
    let aad = hex("50515253c0c1c2c3c4c5c6c7")
    let plaintext = hex("""
        4c616469657320616e642047656e746c656d656e206f662074686520636c6173
        73206f66202739393a204966204920636f756c64206f6666657220796f75206f
        6e6c79206f6e652074697020666f7220746865206675747572652c2073756e73
        637265656e20776f756c642062652069742e
        """)
    let ciphertext = hex("""
        bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb
        731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b452
        2f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff9
        21f9664c97637da9768812f615c68b13b52e
        """)
    let tag = hex("c0875924c1c7987947deafd8780acf49")

    func testHChaCha20DraftVector() {
        let k = (0..<32).map { UInt8($0) }
        let n = hex("000000090000004a0000000031415927")
        XCTAssertEqual(XChaCha.hChaCha20(key: k, nonce16: n),
                       hex("82413b4227b27bfed30e42508a877d73a0f9e4d58a74a853c12ec41326d3ecdc"))
    }

    func testXChaChaPolyDraftVector() throws {
        let out = try XChaCha.open(key: Data(key), nonce: Data(nonce), sealed: Data(ciphertext + tag), aad: Data(aad))
        XCTAssertEqual([UInt8](out), plaintext)
    }

    func testTamperedTagThrows() {
        var t = tag
        t[t.count - 1] ^= 1
        XCTAssertThrowsError(
            try XChaCha.open(key: Data(key), nonce: Data(nonce), sealed: Data(ciphertext + t), aad: Data(aad))
        ) { XCTAssertEqual($0 as? PreviewError, .decrypt) }
    }
}
