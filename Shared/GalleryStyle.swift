import SwiftUI

/// Shared paper-and-ink colors used by the app and the Soft Gallery widget theme.
enum GalleryPalette {
    static func color(_ light: UInt, _ dark: UInt) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
    static let paper = color(0xF2EDE5, 0x1E2329)
    static let card = color(0xFFFDF8, 0x2A3038)
    static let ink = color(0x342D27, 0xEEE7DB)
    static let muted = color(0x7A7065, 0xB4AA9D)
    static let line = color(0xDED8CB, 0x454E59)
    static let accent = color(0xB94D2C, 0xE99B7E)
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
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
