import Combine
import Foundation

@MainActor
final class ServerStore: ObservableObject {
    @Published private(set) var profiles: [ServerProfile] = []
    @Published private(set) var selectedProfileID: UUID?
    @Published private(set) var themeMode: AppThemeMode
    @Published private(set) var revision = 0

    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let profilesKey = "dsh.server-profiles.v1"
    private let selectedProfileKey = "dsh.selected-server.v1"
    private let themeModeKey = "dsh.theme-mode.v1"

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        themeMode = AppThemeMode(rawValue: defaults.string(forKey: themeModeKey) ?? "") ?? .system
        loadProfiles()
        loadSelection()
    }

    var selectedProfile: ServerProfile? {
        guard let selectedProfileID else { return profiles.first }
        return profiles.first { $0.id == selectedProfileID } ?? profiles.first
    }

    func password(for profile: ServerProfile) -> String? {
        keychain.password(for: profile.id)
    }

    func upsert(_ profile: ServerProfile, password: String?) throws {
        let priorProfile = profiles.first { $0.id == profile.id }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        try persistProfiles()
        if let password, !password.isEmpty {
            try keychain.setPassword(password, for: profile.id)
        }
        if priorProfile?.kind == .hermes,
           (priorProfile?.baseURL != profile.baseURL || profile.kind != .hermes) {
            try? keychain.deleteData(for: KeychainStore.hermesTokenAccount(for: profile.id))
        }
        if selectedProfileID == nil {
            select(profile)
        }
        revision += 1
    }

    func select(_ profile: ServerProfile) {
        selectedProfileID = profile.id
        defaults.set(profile.id.uuidString, forKey: selectedProfileKey)
    }

    func setThemeMode(_ mode: AppThemeMode) {
        guard themeMode != mode else { return }
        themeMode = mode
        defaults.set(mode.rawValue, forKey: themeModeKey)
    }

    func remove(_ profile: ServerProfile) {
        profiles.removeAll { $0.id == profile.id }
        try? persistProfiles()
        try? keychain.deletePassword(for: profile.id)
        try? keychain.deleteData(for: KeychainStore.hermesTokenAccount(for: profile.id))
        if selectedProfileID == profile.id {
            selectedProfileID = profiles.first?.id
            if let selectedProfileID {
                defaults.set(selectedProfileID.uuidString, forKey: selectedProfileKey)
            } else {
                defaults.removeObject(forKey: selectedProfileKey)
            }
        }
        revision += 1
    }

    private func loadProfiles() {
        guard let data = defaults.data(forKey: profilesKey),
              let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) else {
            return
        }
        profiles = decoded
    }

    private func persistProfiles() throws {
        defaults.set(try JSONEncoder().encode(profiles), forKey: profilesKey)
    }

    private func loadSelection() {
        if let rawID = defaults.string(forKey: selectedProfileKey),
           let id = UUID(uuidString: rawID),
           profiles.contains(where: { $0.id == id }) {
            selectedProfileID = id
        } else {
            selectedProfileID = profiles.first?.id
        }
    }
}
