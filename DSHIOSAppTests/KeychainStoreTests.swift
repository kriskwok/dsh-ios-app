import XCTest
@testable import DSHIOSApp

final class KeychainStoreTests: XCTestCase {
    func testPasswordRoundTrip() throws {
        let store = KeychainStore()
        let profileID = UUID()
        defer { try? store.deletePassword(for: profileID) }

        try store.setPassword("keychain-round-trip", for: profileID)

        XCTAssertEqual(store.password(for: profileID), "keychain-round-trip")
        try store.deletePassword(for: profileID)
        XCTAssertNil(store.password(for: profileID))
    }

    func testOpaqueDataRoundTrip() throws {
        let store = KeychainStore()
        let account = "test-\(UUID().uuidString)"
        let payload = Data([0, 1, 2, 255])
        defer { try? store.deleteData(for: account) }

        try store.setData(payload, for: account)

        XCTAssertEqual(store.data(for: account), payload)
        try store.deleteData(for: account)
        XCTAssertNil(store.data(for: account))
    }
}
