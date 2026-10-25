import SwiftUI
import UIKit

/// A color stored as components so it can be saved in the App Group and read by widgets.
struct StoredColor: Codable, Equatable {
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
    /// WCAG relative luminance, ignoring opacity.
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
}

/// The user's own widget background: a solid color or two-color gradient, with an optional border.
struct CustomWidgetStyle: Codable, Equatable {
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

    static let key = "customWidgetStyle"
    static var saved: CustomWidgetStyle {
        guard let data = Preferences.defaults.data(forKey: key), let style = try? JSONDecoder().decode(CustomWidgetStyle.self, from: data) else { return CustomWidgetStyle() }
        return style
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { Preferences.defaults.set(data, forKey: Self.key) }
    }
    /// White on dark backgrounds, black on light ones, judged by the average of the fill colors.
    var text: Color {
        let luminance = fill == .solid ? first.luminance : (first.luminance + second.luminance) / 2
        return luminance > 0.36 ? .black : .white
    }
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
