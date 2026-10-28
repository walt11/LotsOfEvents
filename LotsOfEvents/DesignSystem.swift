import SwiftUI
import EventKit

// The pieces every tab is built from, so Calendar, Agenda, Reminders, and search look and behave alike:
// one section header, one row of mode chips, one event row, one toolbar layout, and one search.

/// A list or card section title: sentence case, footnote weight, with an optional count or note on the right.
struct SectionHeader: View {
    let title: String
    var trailing: String? = nil
    var tint: Color = GalleryPalette.muted
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(tint)
            Spacer(minLength: 8)
            if let trailing { Text(trailing).foregroundStyle(GalleryPalette.muted) }
        }
        .font(.footnote.weight(.semibold))
        .textCase(nil)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The row of capsules under the title that switches a tab's view, used by Calendar and Reminders.
/// It scrolls sideways, so it works at every text size, and keeps the chosen chip in view.
struct ChipBar<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    let selected = option == selection
                    Button { withAnimation(.snappy) { selection = option } } label: {
                        Text(title(option)).font(.subheadline.weight(.medium)).lineLimit(1)
                            .padding(.horizontal, 14).frame(minHeight: 36)
                            .foregroundStyle(selected ? GalleryPalette.paper : GalleryPalette.ink)
                            .background(selected ? GalleryPalette.ink : GalleryPalette.card, in: Capsule())
                            .overlay { Capsule().strokeBorder(GalleryPalette.line, lineWidth: selected ? 0 : 0.5) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .id(option)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .padding(.bottom, 6)
        .onAppear { proxy.scrollTo(selection, anchor: .center) }
        .onChange(of: selection) { _, value in withAnimation(.snappy) { proxy.scrollTo(value, anchor: .center) } }
        }
    }
}

/// An event in any list: calendar color bar, title, badges, a detail line, the time on the right, and Join for calls.
/// A reminder can pass its completion button as `leading`.
struct EventRow<Leading: View>: View {
    let color: Color
    let title: String
    var detail: String? = nil
    var time: String? = nil
    var birthday = false
    var needsReply = false
    var conflict = false
    var joinURL: URL? = nil
    var dimmed = false
    let open: () -> Void
    @ViewBuilder var leading: () -> Leading
    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4)
                    leading()
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            if birthday { Image(systemName: "gift.fill").foregroundStyle(color).accessibilityLabel("Birthday") }
                            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(GalleryPalette.ink)
                        }
                        EventBadges(needsReply: needsReply, conflict: conflict)
                        if let detail { Text(detail).font(.caption).foregroundStyle(GalleryPalette.muted).lineLimit(1) }
                    }
                    Spacer(minLength: 4)
                    if let time { Text(time).font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(GalleryPalette.muted).multilineTextAlignment(.trailing) }
                }
                .frame(minHeight: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Separate from the row's button so each can be tapped.
            if let joinURL { JoinButton(url: joinURL) }
        }
        .opacity(dimmed ? 0.45 : 1)
    }
}

extension EventRow where Leading == EmptyView {
    init(color: Color, title: String, detail: String? = nil, time: String? = nil, birthday: Bool = false, needsReply: Bool = false,
         conflict: Bool = false, joinURL: URL? = nil, dimmed: Bool = false, open: @escaping () -> Void) {
        self.init(color: color, title: title, detail: detail, time: time, birthday: birthday, needsReply: needsReply,
                  conflict: conflict, joinURL: joinURL, dimmed: dimmed, open: open, leading: { EmptyView() })
    }
}

extension EKEvent {
    /// "9:00 AM – 10:00 AM", or "All day".
    var timeRange: String {
        isAllDay ? "All day" : "\(startDate.formatted(date: .omitted, time: .shortened)) – \(endDate.formatted(date: .omitted, time: .shortened))"
    }
}

extension View {
    /// Every tab's toolbar: what's shown on the left, then Today (where it applies) and Search on the right.
    func tabToolbar<Filter: View>(model: AgendaModel, today: (() -> Void)? = nil, @ViewBuilder filter: () -> Filter) -> some View {
        let filter = filter()
        return toolbar {
            ToolbarItem(placement: .topBarLeading) { filter }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let today { Button("Today", action: today) }
                Button("Search", systemImage: "magnifyingglass") { model.sheet = .search }
            }
        }
    }
}

/// Search across events (a year either side of today) and open reminders, from any tab.
struct SearchSheet: View {
    @ObservedObject var model: AgendaModel
    @State private var query = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView("Search everything", systemImage: "magnifyingglass",
                                           description: Text("Find events by title, place, notes, or calendar, and reminders by title, notes, or list."))
                } else {
                    UnifiedSearchResults(model: model, query: query.trimmingCharacters(in: .whitespaces))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GalleryPalette.paper)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Events and reminders")
            .searchFocused($focused)
            .onAppear { focused = true }
            .navigationTitle("Search").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
