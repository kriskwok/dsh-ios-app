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

    func testDisablingSelectedServerFallsBackAndBlocksReselection() throws {
        let suiteName = "ServerStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let enabled = ServerProfile(name: "Enabled", baseURL: URL(string: "https://enabled.example.com")!)
        let disabled = ServerProfile(
            name: "Disabled",
            baseURL: URL(string: "https://disabled.example.com")!,
            isEnabled: false
        )
        let store = ServerStore(defaults: defaults)
        try store.upsert(enabled, password: nil)
        try store.upsert(disabled, password: nil)
        store.select(disabled)
        XCTAssertEqual(store.selectedProfile?.id, enabled.id)
        XCTAssertEqual(store.enabledProfiles.map(\.id), [enabled.id])

        store.select(disabled)
        XCTAssertEqual(store.selectedProfile?.id, enabled.id)

        let restored = ServerStore(defaults: defaults)
        XCTAssertEqual(restored.profiles.first(where: { $0.id == disabled.id })?.isEnabled, false)
    }

    func testEditingDisabledServerPreservesDisabledState() throws {
        let suiteName = "ServerStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let original = ServerProfile(
            name: "Disabled",
            baseURL: URL(string: "https://disabled.example.com")!,
            isEnabled: false
        )
        let store = ServerStore(defaults: defaults)
        try store.upsert(original, password: nil)

        let edited = try ServerProfile.validated(
            id: original.id,
            name: "Renamed",
            address: "https://disabled.example.com",
            username: "",
            isEnabled: original.isEnabled
        )
        try store.upsert(edited, password: nil)

        XCTAssertEqual(store.profiles.first(where: { $0.id == original.id })?.isEnabled, false)
    }
}
