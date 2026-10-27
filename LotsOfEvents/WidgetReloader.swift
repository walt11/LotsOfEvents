import WidgetKit

/// Batches widget reloads: bursts of changes (store notifications, color-picker drags, several saves)
/// become one reload a moment after they stop.
@MainActor
enum WidgetReloader {
    private static var pending: Task<Void, Never>?
    static func schedule(after delay: Duration = .seconds(1)) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
