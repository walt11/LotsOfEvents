import SwiftUI

/// The app's color themes. Each sets its own light or dark appearance, replacing the old System/Light/Dark choice.
enum AppTheme: String, CaseIterable, Identifiable {
    case light, dark, graphite, midnight, forest, studio
    static let key = "appTheme"
    /// Read from the shared App Group, so widgets use the same default accent.
    static var current: AppTheme { AppTheme(rawValue: Preferences.defaults.string(forKey: key) ?? "") ?? .graphite }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .graphite: return "Graphite"
        case .midnight: return "Midnight"
        case .forest: return "Forest"
        case .studio: return "Studio"
        }
    }
    var scheme: ColorScheme { self == .light || self == .studio ? .light : .dark }
    /// Every pair of text and background here keeps at least 4.5:1 contrast.
    var colors: (paper: UInt, card: UInt, ink: UInt, muted: UInt, line: UInt, accent: UInt, onAccent: UInt) {
        switch self {
        // iOS system light and dark, with the system blue deepened or lifted just enough to read as text.
        case .light: return (0xF2F2F7, 0xFFFFFF, 0x000000, 0x6C6C70, 0xC6C6C8, 0x0062CC, 0xFFFFFF)
        case .dark: return (0x000000, 0x1C1C1E, 0xFFFFFF, 0x98989F, 0x38383A, 0x409CFF, 0x000000)
        case .graphite: return (0x0D0E0F, 0x1A1B1D, 0xECEDEE, 0xA2A5AA, 0x303236, 0x8DB4DE, 0x0D0E0F)
        case .midnight: return (0x0A0F1C, 0x141C2E, 0xE8EDF7, 0x9AA6BD, 0x27324A, 0x64D2FF, 0x0A0F1C)
        case .forest: return (0x0E1411, 0x18211C, 0xE6EEE8, 0x9DB0A4, 0x2A3A31, 0x30D158, 0x0E1411)
        // Studio: off-white page, warm paper cards, near-black ink, rust accent (after the LotsOfFrames app).
        case .studio: return (0xF2F2F0, 0xF7F5ED, 0x292B2E, 0x5C5E63, 0xDCD8CE, 0xA9401F, 0xFFFFFF)
        }
    }
    /// The matching Home Screen icon; nil is the primary (Graphite) icon. Made by scripts/GenerateThemeIcons.swift.
    var iconName: String? { self == .graphite ? nil : "AppIcon-\(title)" }
    /// Carries over the old appearance setting once: Light keeps a light theme, anything else gets Graphite.
    static func migrateFromAppearance() {
        guard Preferences.defaults.string(forKey: key) == nil else { return }
        let old = UserDefaults.standard.string(forKey: "appAppearance")
        Preferences.defaults.set((old == "light" ? AppTheme.light : .graphite).rawValue, forKey: key)
    }
}

/// The current theme's colors. Views read these directly; the app rebuilds its views when the theme changes.
enum GalleryPalette {
    static func hex(_ value: UInt) -> Color {
        Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    static var paper: Color { hex(AppTheme.current.colors.paper) }
    static var card: Color { hex(AppTheme.current.colors.card) }
    static var ink: Color { hex(AppTheme.current.colors.ink) }
    static var muted: Color { hex(AppTheme.current.colors.muted) }
    static var line: Color { hex(AppTheme.current.colors.line) }
    static var accent: Color { hex(AppTheme.current.colors.accent) }
    /// Text drawn on the default accent.
    static var onAccent: Color { hex(AppTheme.current.colors.onAccent) }
}

extension View {
    func gallerySurface(radius: CGFloat = 16) -> some View {
        background(GalleryPalette.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(GalleryPalette.line, lineWidth: 0.5) }
    }
    func galleryTitle(_ title: String) -> some View {
        toolbar {
            ToolbarItem(placement: .principal) {
                Text(title).font(.system(.title3, design: .serif)).italic().foregroundStyle(GalleryPalette.ink)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }
    func galleryRow() -> some View {
        padding(.horizontal, 10).padding(.vertical, 7)
            .gallerySurface(radius: 12)
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
}
