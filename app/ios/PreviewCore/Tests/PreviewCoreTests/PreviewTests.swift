import XCTest
@testable import PreviewCore

final class PreviewTests: XCTestCase {
    func testNoKeyringKeepsGenericAlert() throws {
        let fixture = try Fixture.load()
        let c = try XCTUnwrap(fixture.cases.first { $0.name == "text-direct" })
        XCTAssertNil(Preview.notificationBody(userInfo: c.userInfo, keyring: nil))
    }

    func testKeyringWrongVersionIsNil() {
        let json = #"{"v":2,"keys":{},"devices":{},"groups":[],"names":{}}"#
        XCTAssertNil(Keyring.parse(Data(json.utf8)))
        let ok = #"{"v":1,"keys":{},"devices":{},"groups":[],"names":{}}"#
        XCTAssertNotNil(Keyring.parse(Data(ok.utf8)))
    }

    func testMediaLabels() {
        XCTAssertEqual(Preview.mediaLabel("photo"), "📷 Photo")
        XCTAssertEqual(Preview.mediaLabel("voice"), "🎤 Voice message")
        XCTAssertEqual(Preview.mediaLabel("video"), "🎥 Video")
        XCTAssertEqual(Preview.mediaLabel("gif"), "GIF")
        XCTAssertNil(Preview.mediaLabel("text"))
    }
}
