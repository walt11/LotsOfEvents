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
    case app, charcoal, gallery, graphite, slate, sage, sand, clay, lavender, black, custom
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Theme"
    static let caseDisplayRepresentations: [WidgetThemeOption: DisplayRepresentation] = [
        .app: "Same as app", .charcoal: "Charcoal", .gallery: "Soft Gallery", .graphite: "Graphite", .slate: "Slate", .sage: "Sage", .sand: "Sand", .clay: "Clay", .lavender: "Lavender", .black: "Black", .custom: "Custom (from the app)"
    ]
    /// nil follows the theme chosen in the app's Sources screen.
    var theme: AgendaTheme? { AgendaTheme(rawValue: rawValue) }
}

struct AgendaConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Agenda Options"
    static let description = IntentDescription("Choose this widget's theme and which calendars and reminder lists it shows.")
    @Parameter(title: "Theme", default: .app) var theme: WidgetThemeOption
    @Parameter(title: "Calendars and Lists", description: "Leave empty to use the selections in the app's Sources screen.") var sources: [SourceEntity]?
}
