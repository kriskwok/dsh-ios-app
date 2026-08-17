import SwiftUI

@main
struct DSHIOSAppApp: App {
    @StateObject private var serverStore = ServerStore()

    var body: some Scene {
        WindowGroup {
            AppShellView()
                .environmentObject(serverStore)
                .preferredColorScheme(preferredColorScheme)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch serverStore.themeMode {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}
