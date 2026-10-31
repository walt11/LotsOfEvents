import SwiftUI
import Contacts
import WidgetKit

private actor ContactDateReader {
    func read() throws -> [ContactDateRecord] {
        let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactIdentifierKey as CNKeyDescriptor,
                    CNContactBirthdayKey as CNKeyDescriptor, CNContactNonGregorianBirthdayKey as CNKeyDescriptor,
                    CNContactDatesKey as CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        var records: [ContactDateRecord] = []
        try CNContactStore().enumerateContacts(with: request) { contact, _ in
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? "Contact"
            if let birthday = contact.nonGregorianBirthday ?? contact.birthday {
                records.append(ContactDateRecord(id: contact.identifier + ":birthday", contactID: contact.identifier,
                                                 name: name, label: "Birthday", components: birthday, birthday: true))
            }
            for date in contact.dates {
                let label = date.label.map { CNLabeledValue<NSDateComponents>.localizedString(forLabel: $0) } ?? "Date"
                records.append(ContactDateRecord(id: contact.identifier + ":" + date.identifier, contactID: contact.identifier,
                                                 name: name, label: label, components: date.value as DateComponents, birthday: false))
            }
        }
        return records.sorted { $0.id < $1.id }
    }
}

@MainActor enum ContactDateSync {
    private static let reader = ContactDateReader()
    static var allowed: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        return status == .authorized || status == .limited
    }
    static func refresh() async throws {
        guard ContactDates.enabled && allowed else { clear(); return }
        let records = try await reader.read()
        // Permission or the setting can change while the read is running.
        guard ContactDates.enabled && allowed else { clear(); return }
        let data = try JSONEncoder().encode(records)
        if Preferences.defaults.data(forKey: ContactDates.cacheKey) != data {
            Preferences.defaults.set(data, forKey: ContactDates.cacheKey)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
    static func clear() {
        if Preferences.defaults.object(forKey: ContactDates.cacheKey) != nil {
            Preferences.defaults.removeObject(forKey: ContactDates.cacheKey)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

struct ContactDatesSettings: View {
    @ObservedObject var model: AgendaModel
    @AppStorage(ContactDates.enabledKey, store: Preferences.defaults) private var enabled = false
    @State private var connecting = false
    @State private var problem: String?
    var body: some View {
        Section {
            Toggle("Dates from Contacts", isOn: Binding(get: { enabled }, set: { on in
                if !on { enabled = false; ContactDateSync.clear(); model.scheduleRefresh(); return }
                connecting = true
                Task {
                    defer { connecting = false }
                    do {
                        let granted = try await CNContactStore().requestAccess(for: .contacts)
                        guard granted else { problem = "Allow Contacts access in system Settings to show contact dates."; return }
                        enabled = true
                        try await ContactDateSync.refresh()
                        model.scheduleRefresh()
                    } catch { problem = error.localizedDescription }
                }
            })).disabled(connecting)
            if connecting { ProgressView("Connecting Contacts…") }
            if enabled {
                Text("\(ContactDates.records.count) dated fields available").font(.footnote).foregroundStyle(.secondary)
                if CNContactStore.authorizationStatus(for: .contacts) == .limited {
                    Text("Only contacts you have shared with LotsOfEvents are included.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: { Text("Contacts") } footer: {
            Text("Show birthdays, anniversaries, and custom dates as yearly, all-day events in the calendar, agenda, and widgets. Existing calendar birthdays are not duplicated. Edit dates in Contacts. February 29 appears on February 28 in other years. Contact dates stay on your devices.")
        }
        .listRowBackground(GalleryPalette.card)
        .alert("Contacts Access", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            Button("OK", role: .cancel) { problem = nil }
        } message: { Text(problem ?? "") }
    }
}

struct ContactDateDetails: View {
    let record: ContactDateRecord
    let date: Date
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Contact", value: record.name)
                    LabeledContent("Occasion", value: record.label)
                    LabeledContent("Date", value: date.formatted(date: .complete, time: .omitted))
                    LabeledContent("Repeats", value: "Every year · All day")
                }
                Section { Text("This date comes from Contacts. To change or remove it, edit the date on the contact’s card in Contacts.") }
            }
            .navigationTitle(record.label)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(idealWidth: 520, idealHeight: 420)
    }
}
