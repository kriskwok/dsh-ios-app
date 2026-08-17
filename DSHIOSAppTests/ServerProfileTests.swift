import XCTest
@testable import DSHIOSApp

final class ServerProfileTests: XCTestCase {
    func testAddsHTTPSAndNormalizesRootURL() throws {
        let profile = try ServerProfile.validated(
            name: "  Production  ",
            address: "DSH.EXAMPLE.COM/",
            username: " user "
        )
        XCTAssertEqual(profile.name, "Production")
        XCTAssertEqual(profile.baseURL.absoluteString, "https://dsh.example.com")
        XCTAssertEqual(profile.username, "user")
    }

    func testRejectsPublicHTTP() {
        XCTAssertThrowsError(try ServerProfile.validated(
            name: "Unsafe",
            address: "http://dsh.example.com",
            username: ""
        )) { error in
            XCTAssertEqual(error as? ServerProfile.ValidationError, .insecureRemoteURL)
        }
    }

    func testAllowsLocalHTTPHostname() throws {
        let profile = try ServerProfile.validated(
            name: "LAN",
            address: "http://dshbox.local:3080",
            username: ""
        )
        XCTAssertEqual(profile.baseURL.absoluteString, "http://dshbox.local:3080")
    }

    func testRejectsSubpathBecauseDSHUsesRootRelativeAPIPaths() {
        XCTAssertThrowsError(try ServerProfile.validated(
            name: "Bad path",
            address: "https://example.com/dsh",
            username: ""
        )) { error in
            XCTAssertEqual(error as? ServerProfile.ValidationError, .pathNotSupported)
        }
    }

    func testAllowsHermesBehindHTTPSSubpath() throws {
        let profile = try ServerProfile.validated(
            kind: .hermes,
            name: "Hermes",
            address: "https://agent.example.com/hermes/",
            username: "admin"
        )

        XCTAssertEqual(profile.kind, .hermes)
        XCTAssertEqual(profile.baseURL.absoluteString, "https://agent.example.com/hermes")
    }

    func testDecodesExistingProfileAsDSH() throws {
        let id = UUID()
        let data = Data("""
        {"id":"\(id.uuidString)","name":"Existing","baseURL":"https://dsh.example.com","username":"admin"}
        """.utf8)

        let profile = try JSONDecoder().decode(ServerProfile.self, from: data)

        XCTAssertEqual(profile.kind, .dsh)
    }
}
