import UIKit
import SwiftUI
import EventKit
import UniformTypeIdentifiers

/// "LotsOfEvents" in any app's share sheet for calendar files (pCloud, Dropbox, Mail, Files, and others):
/// reads the shared .ics and shows the same Add to Calendar sheet as the app, right inside the share sheet.
final class ShareViewController: UIViewController {
    private let store = EKEventStore()

    override func viewDidLoad() {
        super.viewDidLoad()
        // The share sheet follows the system appearance; the theme sets its own. Without the App Group
        // (not yet assigned to this extension's App ID), this is the default theme rather than the user's.
        overrideUserInterfaceStyle = AppTheme.current.scheme == .dark ? .dark : .light
        show(AnyView(ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(GalleryPalette.paper)))
        Task { await load() }
    }

    private func load() async {
        let events = await sharedEvents()
        guard await calendarAccess() else {
            show(AnyView(message("Calendar access needed", symbol: "calendar.badge.exclamationmark",
                                 detail: "Open LotsOfEvents and allow access to your calendars, then share the file again.")))
            return
        }
        show(AnyView(ICSImportView(store: store, events: events, finish: { [weak self] in self?.close() })))
    }

    /// Every calendar file attached to the share, read as text and parsed.
    private func sharedEvents() async -> [ICSEvent] {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var events: [ICSEvent] = []
        for provider in providers {
            guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .calendarEvent) == true })
                    ?? provider.registeredTypeIdentifiers.first(where: { $0 == UTType.fileURL.identifier }) else { continue }
            if let data = await Self.data(from: provider, type: type) {
                let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
                events += ICSParser.parse(text)
            }
        }
        return events
    }

    /// The file's contents, whether the app shared the data itself or a link to a file.
    private static func data(from provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            if type == UTType.fileURL.identifier {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url.flatMap { try? ICSParser.data(at: $0) })
                }
            } else {
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in continuation.resume(returning: data) }
            }
        }
    }

    private func calendarAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .notDetermined: return (try? await store.requestFullAccessToEvents()) ?? false
        default: return false
        }
    }

    private func message(_ title: String, symbol: String, detail: String) -> some View {
        NavigationStack {
            ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(GalleryPalette.paper)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { [weak self] in self?.close() } } }
        }
    }

    private func show(_ view: AnyView) {
        children.forEach { $0.willMove(toParent: nil); $0.view.removeFromSuperview(); $0.removeFromParent() }
        // The theme's colors and accent, matching the appearance set above.
        let host = UIHostingController(rootView: view.preferredColorScheme(AppTheme.current.scheme).tint(GalleryPalette.accent))
        addChild(host)
        host.view.frame = self.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    private func close() { extensionContext?.completeRequest(returningItems: nil) }
}
