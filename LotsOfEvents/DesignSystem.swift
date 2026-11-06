import SwiftUI
import EventKit

// The pieces every tab is built from, so Calendar, Agenda, Reminders, and search look and behave alike:
// one section header, one row of mode chips, one event row, one toolbar layout, and one search.

/// The row of capsules under the title that switches a tab's view, used by Calendar and Reminders.
/// It scrolls sideways, so it works at every text size, and keeps the chosen chip in view.
struct ChipBar<Value: Hashable>: View {
    @AppAccent private var accent
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
                            .foregroundStyle(selected ? _accent.contrastingText : GalleryPalette.ink)
                            .background(selected ? accent : .clear, in: Capsule())
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
    var contactDateSymbol: String? = nil
    var needsReply = false
    var conflict = false
    var joinURL: URL? = nil
    var dimmed = false
    let open: () -> Void
    @ViewBuilder var leading: () -> Leading
    var body: some View {
        HStack(spacing: 8) {
            leading()
            Button(action: open) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            if let symbol = birthday ? "gift.fill" : contactDateSymbol { Image(systemName: symbol).foregroundStyle(color).accessibilityLabel(symbol == "gift.fill" ? "Birthday" : symbol == "heart.fill" ? "Anniversary" : "Date from Contacts") }
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
        .opacity(dimmed ? 0.65 : 1)
    }
}

extension EventRow where Leading == EmptyView {
    init(color: Color, title: String, detail: String? = nil, time: String? = nil, birthday: Bool = false, contactDateSymbol: String? = nil, needsReply: Bool = false,
         conflict: Bool = false, joinURL: URL? = nil, dimmed: Bool = false, open: @escaping () -> Void) {
        self.init(color: color, title: title, detail: detail, time: time, birthday: birthday, contactDateSymbol: contactDateSymbol, needsReply: needsReply,
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
                                           description: Text("Find events by title, place, notes, or calendar, reminders by title, notes, or list, and dates from Contacts. Filter results by upcoming, past, or completed."))
                } else {
                    UnifiedSearchResults(model: model, query: query.trimmingCharacters(in: .whitespaces))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GalleryPalette.paper)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Events, tasks, and contact dates")
            .searchFocused($focused)
            .onAppear { focused = true }
            .navigationTitle("Search").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Touch and hold an agenda item for Delete, below any other actions the row offers.
/// A repeating event asks whether to delete just this one or all future ones, like Apple's Calendar.
private struct DeletableAgendaItem<Extra: View>: ViewModifier {
    @ObservedObject var model: AgendaModel
    let item: AgendaItem
    let extra: Extra
    @State private var repeating: EKEvent?
    func body(content: Content) -> some View {
        content
            .contextMenu {
                extra
                // Birthdays come from Contacts and can't be deleted here.
                if !item.birthday && item.contactDateID == nil {
                    Button(item.reminder ? "Delete Reminder" : "Delete Event", systemImage: "trash", role: .destructive, action: delete)
                }
            }
            .confirmationDialog("This is a repeating event.", isPresented: Binding(get: { repeating != nil }, set: { if !$0 { repeating = nil } }),
                                titleVisibility: .visible, presenting: repeating) { event in
                Button("Delete This Event Only", role: .destructive) { model.delete(event, span: .thisEvent) }
                Button("Delete All Future Events", role: .destructive) { model.delete(event, span: .futureEvents) }
            }
    }
    private func delete() {
        if item.reminder {
            guard let reminder = model.reminder(withID: item.sourceID ?? item.id) else { model.error = "This reminder no longer exists. Refresh your agenda."; return }
            guard reminder.calendar?.allowsContentModifications == true else { model.error = "This list is read-only."; return }
            do { try model.delete(reminder) } catch { model.error = error.localizedDescription }
        } else {
            guard let event = model.event(for: item) else { model.error = "This event changed or was removed. Refresh your agenda."; return }
            if event.hasRecurrenceRules { repeating = event } else { model.delete(event) }
        }
    }
}

extension View {
    func deletableAgendaItem<Extra: View>(model: AgendaModel, item: AgendaItem, @ViewBuilder extra: () -> Extra = { EmptyView() }) -> some View {
        modifier(DeletableAgendaItem(model: model, item: item, extra: extra()))
    }
}
