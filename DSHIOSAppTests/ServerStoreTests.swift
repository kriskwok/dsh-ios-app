import XCTest
@testable import DSHIOSApp

@MainActor
final class ServerStoreTests: XCTestCase {
    func testSelectedServerPersistsAndFallsBackAfterRemoval() throws {
        let suiteName = "ServerStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = ServerProfile(name: "A", baseURL: URL(string: "https://a.example.com")!)
        let second = ServerProfile(name: "B", baseURL: URL(string: "https://b.example.com")!)
        let store = ServerStore(defaults: defaults)
        try store.upsert(first, password: nil)
        try store.upsert(second, password: nil)
        store.select(second)

        let restored = ServerStore(defaults: defaults)
        XCTAssertEqual(restored.selectedProfile?.id, second.id)

        restored.remove(second)
        XCTAssertEqual(restored.selectedProfile?.id, first.id)
    }
}
