import SwiftUI
import UIKit

/// A color stored as components so it can be saved in the App Group and read by widgets.
struct StoredColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var opacity: Double = 1
    init(red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.opacity = opacity
    }
    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Double(r), green: Double(g), blue: Double(b), opacity: Double(a))
    }
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity) }
    /// As a 0xRRGGBB value, ignoring opacity.
    var hex: UInt {
        let channel = { (value: Double) in UInt((min(1, max(0, value)) * 255).rounded()) }
        return channel(red) << 16 | channel(green) << 8 | channel(blue)
    }
    /// WCAG relative luminance, ignoring opacity.
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// The user's own widget background: a solid color or two-color gradient, with an optional border.
struct CustomWidgetStyle: Codable, Hashable {
    enum Fill: String, Codable, CaseIterable { case solid = "Solid", gradient = "Gradient" }
    enum Direction: String, Codable, CaseIterable {
        case down = "Top to bottom", across = "Left to right", diagonalDown = "Diagonal ↘", diagonalUp = "Diagonal ↗"
        var points: (start: UnitPoint, end: UnitPoint) {
            switch self {
            case .down: return (.top, .bottom)
            case .across: return (.leading, .trailing)
            case .diagonalDown: return (.topLeading, .bottomTrailing)
            case .diagonalUp: return (.bottomLeading, .topTrailing)
            }
        }
    }
    var fill = Fill.gradient
    var first = StoredColor(red: 0.16, green: 0.38, blue: 0.86)
    var second = StoredColor(red: 0.42, green: 0.25, blue: 0.82)
    var direction = Direction.diagonalDown
    var borderWidth: Double = 0
    var borderColor = StoredColor(red: 1, green: 1, blue: 1, opacity: 0.6)
    /// Day highlights and "Next up" text on custom widgets; nil follows the app accent.
    var accent: StoredColor? = nil
    /// The main and secondary text colors; nil picks black or white to suit the fill.
    var textColor: StoredColor? = nil
    var secondaryColor: StoredColor? = nil

    static let key = "customWidgetStyle"
    static var saved: CustomWidgetStyle {
        guard let data = Preferences.defaults.data(forKey: key), let style = try? JSONDecoder().decode(CustomWidgetStyle.self, from: data) else { return CustomWidgetStyle() }
        return style
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { Preferences.defaults.set(data, forKey: Self.key) }
    }
    /// The chosen text color, or white on dark backgrounds and black on light ones, judged by the average of the fill colors.
    var text: Color {
        if let textColor { return textColor.color }
        let luminance = fill == .solid ? first.luminance : (first.luminance + second.luminance) / 2
        return luminance > 0.36 ? .black : .white
    }
    var secondary: Color { secondaryColor?.color ?? text.opacity(0.6) }
    /// Black or white, whichever reads better on the accent.
    static func contrastingText(on color: StoredColor) -> Color { color.luminance > 0.179 ? .black : .white }
    @ViewBuilder var fillView: some View {
        if fill == .solid { first.color }
        else { LinearGradient(colors: [first.color, second.color], startPoint: direction.points.start, endPoint: direction.points.end) }
    }
    /// The fill and border, drawn in the widget's own rounded shape.
    var background: some View {
        ZStack {
            fillView
            if borderWidth > 0 {
                ContainerRelativeShape().strokeBorder(borderColor.color, lineWidth: borderWidth)
            }
        }
    }
}

/// Text, spacing, and visibility choices for widgets, whatever their theme. Set for all widgets in the Widget editor;
/// each widget's own options (touch and hold → Edit Widget) can change the font, text size, and spacing for just that widget.
struct WidgetLook: Codable, Equatable, Hashable {
    enum FontStyle: String, Codable, CaseIterable {
        case theme = "Theme default", standard = "Default", rounded = "Rounded", serif = "Serif", mono = "Monospaced"
        var design: Font.Design? {
            switch self {
            case .theme: nil
            case .standard: .default
            case .rounded: .rounded
            case .serif: .serif
            case .mono: .monospaced
            }
        }
    }
    enum TextSize: String, Codable, CaseIterable {
        case small = "Small", standard = "Standard", large = "Large", extraLarge = "Extra large"
        var scale: CGFloat { switch self { case .small: 0.9; case .standard: 1; case .large: 1.12; case .extraLarge: 1.26 } }
    }
    enum Density: String, Codable, CaseIterable {
        case compact = "Compact", standard = "Standard", roomy = "Roomy"
        var factor: CGFloat { switch self { case .compact: 0.88; case .standard: 1; case .roomy: 1.22 } }
    }
    var font = FontStyle.theme
    var textSize = TextSize.standard
    var density = Density.standard
    var showTimes = true
    var showColorBars = true
    var showSectionLabels = true
    var showAddButton = true

    init() {}
    // Missing keys keep their defaults, so options added later don't reset saved looks.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        font = try c.decodeIfPresent(FontStyle.self, forKey: .font) ?? .theme
        textSize = try c.decodeIfPresent(TextSize.self, forKey: .textSize) ?? .standard
        density = try c.decodeIfPresent(Density.self, forKey: .density) ?? .standard
        showTimes = try c.decodeIfPresent(Bool.self, forKey: .showTimes) ?? true
        showColorBars = try c.decodeIfPresent(Bool.self, forKey: .showColorBars) ?? true
        showSectionLabels = try c.decodeIfPresent(Bool.self, forKey: .showSectionLabels) ?? true
        showAddButton = try c.decodeIfPresent(Bool.self, forKey: .showAddButton) ?? true
    }

    static let key = "widgetLook"
    static var saved: WidgetLook {
        guard let data = Preferences.defaults.data(forKey: key), let look = try? JSONDecoder().decode(WidgetLook.self, from: data) else { return WidgetLook() }
        return look
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { Preferences.defaults.set(data, forKey: Self.key) }
    }
    /// A widget font at `size` scaled for the text size, in the chosen style or else the theme's own.
    func font(_ size: CGFloat, _ weight: Font.Weight = .regular, theme: Font.Design = .default) -> Font {
        .system(size: (size * textSize.scale).rounded(), weight: weight, design: font.design ?? theme)
    }
    /// A row height scaled for both the density and the text size, so larger text still fits.
    func row(_ height: CGFloat) -> CGFloat { (height * density.factor * textSize.scale).rounded() }
}

/// Equal side insets keep text away from rounded widget corners in every Home Screen layout.
enum WidgetContentLayout {
    static let insets = EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
}
