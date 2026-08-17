import Foundation

enum AppThemeMode: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "日间"
        case .dark: return "黑夜"
        case .system: return "跟随系统"
        }
    }
}
