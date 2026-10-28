import SwiftUI
import WidgetKit
import ActivityKit

/// The next event's countdown on the Lock Screen and in the Dynamic Island, with Join for video calls.
struct NextEventLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NextEventAttributes.self) { context in
            let state = context.state
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3).fill(AccentStore.color(state.colorRGB)).frame(width: 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title).font(.headline).lineLimit(1)
                    Text("\(state.start.formatted(date: .omitted, time: .shortened)) – \(state.end.formatted(date: .omitted, time: .shortened))\(state.location.map { " · \($0)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 4) {
                    countdown(state).font(.title3.weight(.semibold)).monospacedDigit()
                    if let link = state.joinURL {
                        Link(destination: link) {
                            Label("Join", systemImage: "video.fill").font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 4).background(.green, in: Capsule()).foregroundStyle(.white)
                        }
                    }
                }
            }
            .padding(14)
            .activityBackgroundTint(Color.black.opacity(0.6))
            .activitySystemActionForegroundColor(.white)
            .widgetURL(URL(string: "lotsofevents://calendar"))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(state.start <= .now ? "Now" : "Next", systemImage: "calendar").font(.caption).foregroundStyle(AccentStore.color(state.colorRGB))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    countdown(state).font(.caption.weight(.semibold)).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.title).font(.headline).lineLimit(1)
                            if let location = state.location { Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer()
                        if let link = state.joinURL {
                            Link(destination: link) { Label("Join", systemImage: "video.fill").font(.caption.weight(.semibold)) }.tint(.green)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: state.joinURL == nil ? "calendar" : "video.fill").foregroundStyle(AccentStore.color(state.colorRGB))
            } compactTrailing: {
                countdown(state).monospacedDigit().frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "calendar").foregroundStyle(AccentStore.color(state.colorRGB))
            }
            .widgetURL(URL(string: "lotsofevents://calendar"))
        }
    }
    /// Counts down to the start, then shows the time left until the end.
    private func countdown(_ state: NextEventAttributes.ContentState) -> Text {
        state.start > .now ? Text(timerInterval: Date.now...state.start, countsDown: true) : Text(timerInterval: state.start...state.end, countsDown: true)
    }
}
