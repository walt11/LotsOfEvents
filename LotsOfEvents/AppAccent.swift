import SwiftUI

/// A shared, persistent app accent; calendar and widget palettes remain independent.
@propertyWrapper
struct AppAccent: DynamicProperty {
    @AppStorage("appAccentRGB") private var rgb = -1
    var wrappedValue: Color {
        get {
            if rgb == -1 { return .blue }
            return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255) }
        nonmutating set {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard UIColor(newValue).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
            rgb = (Int((red * 255).rounded()) << 16) | (Int((green * 255).rounded()) << 8) | Int((blue * 255).rounded())
        }
    }
    var projectedValue: Binding<Color> { Binding(get: { wrappedValue }, set: { wrappedValue = $0 }) }
    func reset() { rgb = -1 }
    var contrastingText: Color {
        if rgb == -1 { return .white }
        let channels = [Double((rgb >> 16) & 255), Double((rgb >> 8) & 255), Double(rgb & 255)].map { value -> Double in
            let c = value / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722 > 0.179 ? .black : .white
    }
}
