import Foundation
import SwiftData

/// Turns links into notes: added by hand, or shared into the app (`ShareImport`).
@MainActor
enum LinkImport {
    /// An address without fragment and trailing slash, for finding the same link twice.
    static func normalized(_ address: String) -> String {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else { return address }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        var text = components.string ?? address
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    static func knownAddresses(in context: ModelContext) -> [String: Note] {
        var result: [String: Note] = [:]
        for note in (try? context.fetch(FetchDescriptor<Note>())) ?? [] {
            if let url = note.url { result[normalized(url)] = note }
        }
        return result
    }

    /// An address typed by hand: `nil` unless it is a web address; "example.com" becomes "https://example.com".
    static func webAddress(from text: String) -> String? {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !address.contains(" ") else { return nil }
        if !address.lowercased().hasPrefix("http://"), !address.lowercased().hasPrefix("https://") {
            address = "https://" + address
        }
        guard let url = URL(string: address), let host = url.host(), host.contains(".") else { return nil }
        return address
    }

    /// Saves a link added by hand; a link saved before moves to the top instead. Returns its note.
    @discardableResult
    static func add(_ address: String, context: ModelContext, processing: ProcessingService) -> Note {
        var known = knownAddresses(in: context)
        let note = save(address, title: nil, date: Date(), known: &known, context: context, processing: processing)
        try? context.save()
        return note
    }

    static func save(
        _ address: String, title: String?, text: String? = nil, date: Date, known: inout [String: Note],
        context: ModelContext, processing: ProcessingService
    ) -> Note {
        if let existing = known[normalized(address)] {
            // Saved before: it moves to the top of the timeline. Text shared along goes on it if it has none yet.
            if let text, !text.isEmpty, existing.text.isEmpty { existing.text = text }
            existing.deletedAt = nil
            existing.updatedAt = Date()
            return existing
        }
        let note = Note()
        note.url = address
        note.title = title ?? ""
        // Text shared along stays the user's words on the link (never tasks: links make no to-dos).
        note.text = text ?? ""
        note.createdAt = date
        note.updatedAt = date
        note.statusRaw = ProcessingStatus.recorded.rawValue
        note.source = .link
        context.insert(note)
        // It came in here: this device summarizes it once the page is loaded (`AutoSummary`).
        AutoSummary.markOrigin(note.id)
        processing.enqueue(.link(note.id, summarize: true))
        return note
    }
}
