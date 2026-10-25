import AppKit
import SwiftUI

/// Kapitsa's palette: a cold indigo on blue-grey surfaces, after liquid helium.
enum KapitsaTheme {
    static let accent = adaptive(light: 0x4A4FC4, dark: 0x9EA3FF)
    /// Fill behind white text (the Start button): deeper than `accent` so the text stays readable.
    static let accentFill = adaptive(light: 0x4A4FC4, dark: 0x5257D0)
    static let canvas = adaptive(light: 0xF5F6FA, dark: 0x1B1C23)
    static let sidebar = adaptive(light: 0xEBEDF5, dark: 0x22232C)
    static let panel = adaptive(light: 0xFFFFFF, dark: 0x272834)
    static let inset = adaptive(light: 0xEEF0F7, dark: 0x30313E)
    static let border = adaptive(light: 0xDFE2EE, dark: 0x3A3C4A)
    /// Behind words found with Find, with black text on it in both appearances.
    static let findHighlight = adaptive(light: 0xFFE27A, dark: 0xE8C547)
    /// Behind the match Find is on, with white text: unmistakable among the other matches.
    static let findCurrent = adaptive(light: 0xE8590C, dark: 0xF06A1D)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

enum LauncherPage: String, CaseIterable {
    case overview = "Overview"
    case chat = "Chat"
    case settings = "Settings"
    case logs = "Logs"
    case app = "App"

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .chat: return "bubble.left.and.bubble.right"
        case .settings: return "slider.horizontal.3"
        case .logs: return "terminal"
        case .app: return "gearshape"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "Your model, running on your Mac."
        case .chat: return "Talk to your model, with as much thinking as you like."
        case .settings: return "Make Kapitsa work the way you want."
        case .logs: return "A closer look at what your server is doing."
        case .app: return "A few things to make yourself at home."
        }
    }
}
