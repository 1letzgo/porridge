import Foundation
import SwiftData
@testable import Porridge

/// Entries of every kind for the tests of the head, Details and the menus (`EntryMeta`, `EntryDetails`,
/// `EntryMenus`), made the way the app makes them.
@MainActor
enum EntryFixtures {
    static func note(_ title: String = "Note", text: String = "", in context: ModelContext) -> Note {
        let note = Note()
        note.title = title
        note.titleIsCustom = true
        note.text = text
        note.source = .note
        context.insert(note)
        return note
    }

    static func todo(_ title: String = "To-do", text: String = "", due: String? = nil, in context: ModelContext) -> Note {
        let note = note(title, text: text, in: context)
        note.todoState = .open
        note.todoDueDay = due
        return note
    }

    static func meeting(_ title: String = "Design Review", speakers: [String] = [], in context: ModelContext) -> Note {
        let note = note(title, in: context)
        note.source = .meeting
        note.audioFileName = "meeting.m4a"
        note.duration = 42 * 60
        note.speakers = speakers.enumerated().map { Speaker(id: "\($0.offset + 1)", name: $0.element, colorIndex: $0.offset) }
        return note
    }

    static func link(_ address: String = "https://www.example.com/page", in context: ModelContext) -> Note {
        let note = note("Page", in: context)
        note.source = .link
        note.url = address
        return note
    }

    static func image(in context: ModelContext) -> Note {
        let note = note("Photo", in: context)
        note.source = .share
        note.attachments = [Attachment(fileName: "photo.jpg", name: "photo.jpg", kindRaw: Attachment.Kind.image.rawValue)]
        return note
    }

    static func pdf(_ title: String = "Invoice", document: DocumentInfo? = nil, in context: ModelContext) -> Note {
        let note = note(title, in: context)
        note.source = .share
        note.attachments = [Attachment(fileName: "\(UUID().uuidString).pdf", name: "\(title).pdf", kindRaw: Attachment.Kind.pdf.rawValue, document: document)]
        return note
    }

    static func bowl(_ name: String, in context: ModelContext) -> NoteFolder {
        let bowl = NoteFolder(name: name)
        context.insert(bowl)
        return bowl
    }

    static func file(_ note: Note, into bowl: NoteFolder) {
        note.projectIDs = [Projects.key(bowl)]
        note.filedAt = Date()
    }

    /// A day key `days` from today.
    static func day(_ days: Int) -> String {
        Todos.dueKey(Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date())
    }
}
