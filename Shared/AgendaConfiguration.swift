import AppIntents
import EventKit
import WidgetKit

/// A calendar or reminder list that a widget can be limited to.
struct SourceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Calendar or List"
    static let defaultQuery = SourceQuery()
    let id: String
    let title: String
    let account: String
    let reminders: Bool
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(reminders ? "Reminders" : "Calendar") · \(account)")
    }
}

struct SourceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SourceEntity] { all().filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [SourceEntity] { all() }
    private func all() -> [SourceEntity] {
        let store = EKEventStore()
        var result: [SourceEntity] = []
        for (type, reminders) in [(EKEntityType.event, false), (.reminder, true)] where EKEventStore.authorizationStatus(for: type) == .fullAccess {
            result += store.calendars(for: type)
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                .map { SourceEntity(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title, reminders: reminders) }
        }
        return result
    }
}

enum WidgetThemeOption: String, AppEnum {
    case app, matchApp, charcoal, gallery, graphite, slate, sage, sand, clay, lavender, black, custom
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Theme"
    static let caseDisplayRepresentations: [WidgetThemeOption: DisplayRepresentation] = [
        .app: "Same as app", .matchApp: "Match App Theme", .charcoal: "Charcoal", .gallery: "Soft Gallery", .graphite: "Graphite", .slate: "Slate", .sage: "Sage", .sand: "Sand", .clay: "Clay", .lavender: "Lavender", .black: "Black", .custom: "Custom (from the app)"
    ]
    /// nil follows the theme chosen in the app's Sources screen.
    var theme: AgendaTheme? { AgendaTheme(rawValue: rawValue) }
}

/// A widget's own accent for day highlights and headings; "Same as app" follows the app accent.
enum WidgetAccentOption: String, AppEnum {
    case app, blue, teal, green, yellow, orange, red, pink, purple, graphite
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Accent Color"
    static let caseDisplayRepresentations: [WidgetAccentOption: DisplayRepresentation] = [
        .app: "Same as app", .blue: "Blue", .teal: "Teal", .green: "Green", .yellow: "Yellow", .orange: "Orange",
        .red: "Red", .pink: "Pink", .purple: "Purple", .graphite: "Graphite"
    ]
    /// nil follows the app accent.
    var rgb: Int? {
        switch self {
        case .app: nil
        case .blue: 0x2F6FDE
        case .teal: 0x1A9AA6
        case .green: 0x34A853
        case .yellow: 0xE8B730
        case .orange: 0xEF7D22
        case .red: 0xD9443A
        case .pink: 0xE0508B
        case .purple: 0x7E57C8
        case .graphite: 0x5E6670
        }
    }
}

/// A widget's own font; "Same as app" follows the Widget editor.
enum WidgetFontOption: String, AppEnum {
    case app, theme, standard, rounded, serif, mono
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Font"
    static let caseDisplayRepresentations: [WidgetFontOption: DisplayRepresentation] = [
        .app: "Same as app", .theme: "Theme default", .standard: "Default", .rounded: "Rounded", .serif: "Serif", .mono: "Monospaced"
    ]
    var style: WidgetLook.FontStyle? {
        switch self {
        case .app: nil
        case .theme: .theme
        case .standard: .standard
        case .rounded: .rounded
        case .serif: .serif
        case .mono: .mono
        }
    }
}

/// A widget's own text size, so a small widget can stay compact while a large one reads from across the room.
enum WidgetTextSizeOption: String, AppEnum {
    case app, small, standard, large, extraLarge
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Text Size"
    static let caseDisplayRepresentations: [WidgetTextSizeOption: DisplayRepresentation] = [
        .app: "Same as app", .small: "Small", .standard: "Standard", .large: "Large", .extraLarge: "Extra Large"
    ]
    var size: WidgetLook.TextSize? {
        switch self {
        case .app: nil
        case .small: .small
        case .standard: .standard
        case .large: .large
        case .extraLarge: .extraLarge
        }
    }
}

/// A widget's own row spacing.
enum WidgetSpacingOption: String, AppEnum {
    case app, compact, standard, roomy
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Spacing"
    static let caseDisplayRepresentations: [WidgetSpacingOption: DisplayRepresentation] = [
        .app: "Same as app", .compact: "Compact", .standard: "Standard", .roomy: "Roomy"
    ]
    var density: WidgetLook.Density? {
        switch self {
        case .app: nil
        case .compact: .compact
        case .standard: .standard
        case .roomy: .roomy
        }
    }
}

extension WidgetLook {
    /// The Widget editor's look with one widget's own choices on top.
    static func forWidget(font: WidgetFontOption, size: WidgetTextSizeOption, spacing: WidgetSpacingOption) -> WidgetLook {
        var look = WidgetLook.saved
        if let style = font.style { look.font = style }
        if let size = size.size { look.textSize = size }
        if let density = spacing.density { look.density = density }
        return look
    }
}

/// An entry that carries its widget's look.
protocol StyledEntry: TimelineEntry {
    var look: WidgetLook { get set }
}

extension Timeline where EntryType: StyledEntry {
    /// The same timeline with every entry drawn in `look`.
    func styled(_ look: WidgetLook) -> Timeline {
        Timeline(entries: entries.map { var entry = $0; entry.look = look; return entry }, policy: policy)
    }
}

struct AgendaConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Agenda Options"
    static let description = IntentDescription("Choose this widget's theme, text, and which calendars and reminder lists it shows.")
    @Parameter(title: "Theme", default: .app) var theme: WidgetThemeOption
    @Parameter(title: "Accent Color", default: .app) var accent: WidgetAccentOption
    @Parameter(title: "Font", default: .app) var font: WidgetFontOption
    @Parameter(title: "Text Size", default: .app) var textSize: WidgetTextSizeOption
    @Parameter(title: "Spacing", default: .app) var spacing: WidgetSpacingOption
    @Parameter(title: "Calendars and Lists", description: "Leave empty to use the selections in the app's Sources screen.") var sources: [SourceEntity]?
    var look: WidgetLook { .forWidget(font: font, size: textSize, spacing: spacing) }
}

/// The Three-Day Agenda's options add whether to show tasks with complete buttons.
struct ThreeDayConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Three-Day Agenda Options"
    static let description = IntentDescription("Choose this widget's theme, whether it shows tasks, and which calendars and reminder lists it shows.")
    @Parameter(title: "Theme", default: .app) var theme: WidgetThemeOption
    @Parameter(title: "Accent Color", default: .app) var accent: WidgetAccentOption
    @Parameter(title: "Font", default: .app) var font: WidgetFontOption
    @Parameter(title: "Text Size", default: .app) var textSize: WidgetTextSizeOption
    @Parameter(title: "Spacing", default: .app) var spacing: WidgetSpacingOption
    @Parameter(title: "Show Tasks", default: true) var tasks: Bool
    @Parameter(title: "Calendars and Lists", description: "Leave empty to use the selections in the app's Sources screen.") var sources: [SourceEntity]?
    var look: WidgetLook { .forWidget(font: font, size: textSize, spacing: spacing) }
}

/// Events + Tasks has its own options so only it offers the choice of days.
struct EventsTasksConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Events + Tasks Options"
    static let description = IntentDescription("Choose this widget's theme, which days it covers, and which calendars and reminder lists it shows.")
    @Parameter(title: "Theme", default: .app) var theme: WidgetThemeOption
    @Parameter(title: "Accent Color", default: .app) var accent: WidgetAccentOption
    @Parameter(title: "Font", default: .app) var font: WidgetFontOption
    @Parameter(title: "Text Size", default: .app) var textSize: WidgetTextSizeOption
    @Parameter(title: "Spacing", default: .app) var spacing: WidgetSpacingOption
    // A toggle rather than a menu: a plain Bool reaches the widget reliably, where a menu choice reverted to its default.
    @Parameter(title: "Include Upcoming Days", description: "When enabled, uses Days Ahead from the app’s widget settings. Otherwise, shows today only.", default: false) var upcoming: Bool
    @Parameter(title: "Calendars and Lists", description: "Leave empty to use the selections in the app's Sources screen.") var sources: [SourceEntity]?
    var look: WidgetLook { .forWidget(font: font, size: textSize, spacing: spacing) }
}

struct NextUpConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Next Up Options"
    static let description = IntentDescription("Choose this widget's theme, text, and which calendars and reminder lists it shows.")
    @Parameter(title: "Theme", default: .app) var theme: WidgetThemeOption
    @Parameter(title: "Accent Color", default: .app) var accent: WidgetAccentOption
    @Parameter(title: "Font", default: .app) var font: WidgetFontOption
    @Parameter(title: "Text Size", default: .app) var textSize: WidgetTextSizeOption
    @Parameter(title: "Spacing", default: .app) var spacing: WidgetSpacingOption
    @Parameter(title: "Calendars and Lists", description: "Leave empty to use the selections in the app's Sources screen.") var sources: [SourceEntity]?
    @Parameter(title: "Preparation Reminder", description: "Optional reminder to pin beneath your next event. Clear or change it in Edit Widget.") var preparation: PreparationReminderEntity?
    var look: WidgetLook { .forWidget(font: font, size: textSize, spacing: spacing) }
}

struct OpenTimeConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Open Time Options"
    static let description = IntentDescription("Choose this widget's theme, text, and which calendars and reminder lists it shows.")
    @Parameter(title: "Theme", default: .app) var theme: WidgetThemeOption
    @Parameter(title: "Accent Color", default: .app) var accent: WidgetAccentOption
    @Parameter(title: "Font", default: .app) var font: WidgetFontOption
    @Parameter(title: "Text Size", default: .app) var textSize: WidgetTextSizeOption
    @Parameter(title: "Spacing", default: .app) var spacing: WidgetSpacingOption
    @Parameter(title: "Calendars and Lists", description: "Leave empty to use the selections in the app's Sources screen.") var sources: [SourceEntity]?
    @Parameter(title: "Day Starts (0–23)", default: 9) var startHour: Int
    @Parameter(title: "Day Ends (1–24)", default: 17) var endHour: Int
    @Parameter(title: "Minimum Gap (minutes)", default: 30) var minimumMinutes: Int
    var look: WidgetLook { .forWidget(font: font, size: textSize, spacing: spacing) }
}

struct PreparationReminderEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Preparation Reminder"
    static let defaultQuery = PreparationReminderQuery()
    let id: String
    let title: String
    let list: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: "\(list)") }
}
struct PreparationReminderQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PreparationReminderEntity] {
        let store = EKEventStore()
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return [] }
        return identifiers.compactMap { store.calendarItem(withIdentifier: $0) as? EKReminder }
            .filter { !$0.isCompleted }.map { PreparationReminderEntity(id: $0.calendarItemIdentifier, title: $0.title ?? "Reminder", list: $0.calendar?.title ?? "") }
    }
    func suggestedEntities() async throws -> [PreparationReminderEntity] {
        let store = EKEventStore()
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return [] }
        let lists = store.calendars(for: .reminder).filter { Preferences.selected($0.calendarIdentifier, reminders: true) }
        guard !lists.isEmpty else { return [] }
        return await store.reminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists))
            .sorted { ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending }
            .map { PreparationReminderEntity(id: $0.calendarItemIdentifier, title: $0.title ?? "Reminder", list: $0.calendar?.title ?? "") }
    }
}
