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

struct AgendaConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Agenda Options"
    static let description = IntentDescription("Choose this widget's theme and which calendars and reminder lists it shows.")
    @Parameter(title: "Theme", default: .app) var theme: WidgetThemeOption
    @Parameter(title: "Accent Color", default: .app) var accent: WidgetAccentOption
    @Parameter(title: "Calendars and Lists", description: "Leave empty to use the selections in the app's Sources screen.") var sources: [SourceEntity]?
}

/// The Three-Day Agenda's options add whether to show tasks with complete buttons.
struct ThreeDayConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Three-Day Agenda Options"
    static let description = IntentDescription("Choose this widget's theme, whether it shows tasks, and which calendars and reminder lists it shows.")
    @Parameter(title: "Theme", default: .app) var theme: WidgetThemeOption
    @Parameter(title: "Accent Color", default: .app) var accent: WidgetAccentOption
    @Parameter(title: "Show Tasks", default: true) var tasks: Bool
    @Parameter(title: "Calendars and Lists", description: "Leave empty to use the selections in the app's Sources screen.") var sources: [SourceEntity]?
}

/// Events + Tasks has its own options so only it offers the choice of days.
struct EventsTasksConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Events + Tasks Options"
    static let description = IntentDescription("Choose this widget's theme, which days it covers, and which calendars and reminder lists it shows.")
    @Parameter(title: "Theme", default: .app) var theme: WidgetThemeOption
    @Parameter(title: "Accent Color", default: .app) var accent: WidgetAccentOption
    // A toggle rather than a menu: a plain Bool reaches the widget reliably, where a menu choice reverted to its default.
    @Parameter(title: "Include Upcoming Days", default: false) var upcoming: Bool
    @Parameter(title: "Calendars and Lists", description: "Leave empty to use the selections in the app's Sources screen.") var sources: [SourceEntity]?
}
