import SwiftUI
import WidgetKit

/// A shared, persistent app accent; calendar colors and widget backgrounds stay independent.
@MainActor @propertyWrapper
struct AppAccent: DynamicProperty {
    @AppStorage(AccentStore.key, store: Preferences.defaults) private var rgb = -1
    var wrappedValue: Color {
        get { AccentStore.color(rgb) }
        nonmutating set {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard UIColor(newValue).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
            rgb = (Int((red * 255).rounded()) << 16) | (Int((green * 255).rounded()) << 8) | Int((blue * 255).rounded())
            WidgetReloader.schedule()
        }
    }
    var projectedValue: Binding<Color> { Binding(get: { wrappedValue }, set: { wrappedValue = $0 }) }
    func reset() {
        rgb = -1
        WidgetReloader.schedule()
    }
    var contrastingText: Color { AccentStore.contrastingText(rgb) }
    /// True when the user picked their own accent instead of the theme's.
    var isCustom: Bool { rgb != -1 }
}
