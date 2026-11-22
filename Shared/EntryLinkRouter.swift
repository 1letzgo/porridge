import Foundation

/// The app's own links: `porridge://entry/<UUID>` opens that entry (a note, to-do, link, file or meeting). Both apps
/// register the `porridge` scheme; links between entries are stored in this form in the note's Markdown
/// (`EntryLinks`), and the widgets link entries the same way (`QuickAction.openNote`). Only this form counts as a
/// link between entries; `EntryLinkRouter` also opens the older `porridge://note/<UUID>`.
enum PorridgeURL {
    static let scheme = "porridge"
    static let entryHost = "entry"

    /// `porridge://entry/<UUID>`.
    static func entry(_ id: UUID) -> URL {
        URL(string: "\(scheme)://\(entryHost)/\(id.uuidString)")!
    }

    /// The entry a URL opens, or nil when it is no entry link of the app. The UUID's case does not matter.
    static func entryID(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == entryHost else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 1 else { return nil }
        return UUID(uuidString: String(parts[0]))
    }
}

extension Notification.Name {
    /// An entry is to be opened (`EntryLinkRouter`); the list of each app takes it.
    static let porridgeOpenEntry = Notification.Name("de.letzgo.porridge.openEntry")
}

/// The one router of the app's `porridge://` links, for the iPhone app (`onOpenURL`) and the Mac
/// (`application(_:open:)`). `porridge://entry/<UUID>` (and the older `porridge://note/<UUID>`) opens that entry
/// and waits here until a window can show it: on a cold launch the URL comes before any view exists. The other
/// routes (`new`, `meeting`, `inbox`, `todos`, `search?q=…`, see `QuickAction`) go to `QuickActionCenter`; any app
/// or website can open these, so `meeting` only asks whether to start recording.
@MainActor
enum EntryLinkRouter {
    private static var pending: UUID?

    /// Handles `url` when it is a link of the app. Returns false for any other URL.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard let action = QuickAction(url: url) else { return false }
        if case .openNote(let id) = action {
            request(id)
        } else {
            // From outside the app: a meeting recording waits for a confirmation (`fromLink`).
            QuickActionCenter.request(action, fromLink: true)
        }
        return true
    }

    static func request(_ id: UUID) {
        pending = id
        NotificationCenter.default.post(name: .porridgeOpenEntry, object: nil)
    }

    /// The waiting entry, handed out once.
    static func take() -> UUID? {
        defer { pending = nil }
        return pending
    }
}
