import SwiftUI

/// The app's color themes. Each sets its own light or dark appearance, replacing the old System/Light/Dark choice.
enum AppTheme: String, CaseIterable, Identifiable {
    case light, dark, graphite, midnight, forest, studio
    /// The user's own colors from `CustomAppColors`.
    case custom
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
        case .custom: return "Custom"
        }
    }
    var scheme: ColorScheme {
        if self == .custom { return CustomAppColors.saved.dark ? .dark : .light }
        return self == .light || self == .studio ? .light : .dark
    }
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
        case .custom:
            let c = CustomAppColors.saved
            return (c.paper, c.card, c.ink, c.muted, c.line, c.accent, c.onAccent)
        }
    }
    /// The matching Home Screen icon; nil is the primary (Graphite) icon. Made by scripts/GenerateThemeIcons.swift.
    /// Custom has no icon of its own, so choosing it leaves the icon as it was.
    var iconName: String? { self == .graphite || self == .custom ? nil : "AppIcon-\(title)" }
    /// Carries over the old appearance setting once: Light keeps a light theme, anything else gets Graphite.
    static func migrateFromAppearance() {
        guard Preferences.defaults.string(forKey: key) == nil else { return }
        let old = UserDefaults.standard.string(forKey: "appAppearance")
        Preferences.defaults.set((old == "light" ? AppTheme.light : .graphite).rawValue, forKey: key)
    }
}

/// The Custom app theme's colors, kept as hex values in the App Group so the widgets' Match App Theme follows them too.
struct CustomAppColors: Equatable {
    var paper: UInt, card: UInt, ink: UInt, muted: UInt, line: UInt, accent: UInt
    var dark: Bool
    static let key = "customAppColors"
    /// Starts from another theme's colors.
    init(from theme: AppTheme) {
        let c = theme.colors
        self.init(paper: c.paper, card: c.card, ink: c.ink, muted: c.muted, line: c.line, accent: c.accent, dark: theme.scheme == .dark)
    }
    init(paper: UInt, card: UInt, ink: UInt, muted: UInt, line: UInt, accent: UInt, dark: Bool) {
        self.paper = paper; self.card = card; self.ink = ink; self.muted = muted; self.line = line; self.accent = accent; self.dark = dark
    }
    /// Stored as "paper,card,ink,muted,line,accent,dark"; anything unreadable falls back to Graphite.
    static var saved: CustomAppColors {
        let parts = (Preferences.defaults.string(forKey: key) ?? "").split(separator: ",")
        let values = parts.prefix(6).compactMap { UInt($0, radix: 16) }
        guard values.count == 6, parts.count == 7 else { return CustomAppColors(from: .graphite) }
        return CustomAppColors(paper: values[0], card: values[1], ink: values[2], muted: values[3], line: values[4], accent: values[5], dark: parts[6] == "1")
    }
    func save() {
        let hex = [paper, card, ink, muted, line, accent].map { String($0, radix: 16) }
        Preferences.defaults.set((hex + [dark ? "1" : "0"]).joined(separator: ","), forKey: Self.key)
    }
    /// Black or white, whichever reads better on the accent.
    var onAccent: UInt { Self.luminance(accent) > 0.179 ? 0x000000 : 0xFFFFFF }
    static func luminance(_ hex: UInt) -> Double {
        [(hex >> 16) & 255, (hex >> 8) & 255, hex & 255].map { value -> Double in
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }.enumerated().reduce(0) { $0 + $1.element * [0.2126, 0.7152, 0.0722][$1.offset] }
    }
    /// WCAG contrast ratio between two colors.
    static func contrast(_ a: UInt, _ b: UInt) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}

/// How large the app's text is; Automatic follows the iPhone's Text Size setting.
enum AppTextSize: String, CaseIterable, Identifiable {
    case automatic, small, large, extraLarge
    static let key = "appTextSize"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .small: "Small"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }
    var dynamicType: DynamicTypeSize? {
        switch self {
        case .automatic: nil
        case .small: .small
        case .large: .xLarge
        case .extraLarge: .xxxLarge
        }
    }
}

/// How much room rows get in the agenda, calendar, and reminder lists.
enum AppDensity: String, CaseIterable, Identifiable {
    case compact, standard, roomy
    static let key = "appDensity"
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var rowPadding: CGFloat { switch self { case .compact: 4; case .standard: 7; case .roomy: 11 } }
    var rowHeightChange: CGFloat { switch self { case .compact: -8; case .standard: 0; case .roomy: 8 } }
}

/// The app's three main sections in the user's order, plus the one it opens to. Settings always comes last.
enum AppTabs {
    static let orderKey = "tabOrder", startKey = "startTab"
    static let titles = ["Calendar", "Agenda", "Reminders"]
    static func order(_ stored: String) -> [Int] {
        let values = stored.split(separator: ",").compactMap { Int($0) }
        return Set(values) == [0, 1, 2] && values.count == 3 ? values : [0, 1, 2]
    }
    static func stored(_ order: [Int]) -> String { order.map(String.init).joined(separator: ",") }
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
    func galleryRow() -> some View { modifier(GalleryRowModifier()) }
    /// The list's minimum row height, adjusted for the chosen row spacing.
    func appRowHeight(_ base: CGFloat) -> some View { modifier(AppRowHeightModifier(base: base)) }
}

/// Card rows whose padding follows the row spacing setting, updating as soon as it changes.
private struct GalleryRowModifier: ViewModifier {
    @AppStorage(AppDensity.key, store: Preferences.defaults) private var densityID = AppDensity.standard.rawValue
    func body(content: Content) -> some View {
        content.padding(.horizontal, 10).padding(.vertical, (AppDensity(rawValue: densityID) ?? .standard).rowPadding)
            .gallerySurface(radius: 12)
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
    }
}
private struct AppRowHeightModifier: ViewModifier {
    let base: CGFloat
    @AppStorage(AppDensity.key, store: Preferences.defaults) private var densityID = AppDensity.standard.rawValue
    func body(content: Content) -> some View {
        content.environment(\.defaultMinListRowHeight, base + (AppDensity(rawValue: densityID) ?? .standard).rowHeightChange)
    }
}
