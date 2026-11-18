import XCTest
@testable import PreviewCore

struct FixtureCase: Decodable {
    let name: String
    let userInfo: [String: String]
    let expected: String?
}

struct Fixture: Decodable {
    let keyring: String
    let cases: [FixtureCase]

    static func load() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/preview_fixture.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
}

/// Runs every case of the fixture the Dart tests generate (app/test/push/ios_preview_fixture_test.dart).
final class CrossImplementationTests: XCTestCase {
    func testEveryFixtureCase() throws {
        let fixture = try Fixture.load()
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 22)
        let keyring = try XCTUnwrap(Keyring.parse(Data(fixture.keyring.utf8)))
        for c in fixture.cases {
            let got = Preview.notificationBody(userInfo: c.userInfo, keyring: keyring)
            XCTAssertEqual(got, c.expected, "case \(c.name)")
        }
    }
}
