import Foundation

/// The app's own links: `porridge://entry/<UUID>` opens that entry (a note, to-do, link, file or meeting). Both apps
/// register the `porridge` scheme; links between entries are stored in this form in the note's Markdown
/// (`EntryLinks`), and widgets or shortcuts may hand the app the same URL.
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

/// Holds an entry to open until a window can show it: on a cold launch the URL comes before any view exists.
@MainActor
enum EntryLinkRouter {
    private static var pending: UUID?

    /// Handles `url` when it is an entry link of the app. Returns false for any other URL.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard let id = PorridgeURL.entryID(from: url) else { return false }
        request(id)
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
