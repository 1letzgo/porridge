import Foundation
import SwiftData

/// Meetings used to be their own type. They are notes now: this copies each old meeting into a note
/// (same id, title, date, recording, transcript, speakers and summary). The old records stay as a backup
/// and are marked, so nothing is copied twice.
@MainActor
enum LegacyMigration {
    static func run(in context: ModelContext) {
        let meetings = ((try? context.fetch(FetchDescriptor<Meeting>())) ?? []).filter { !$0.migrated }
        guard !meetings.isEmpty else { return }
        let existing = Set(((try? context.fetch(FetchDescriptor<Note>())) ?? []).map(\.id))

        for meeting in meetings {
            if !existing.contains(meeting.id) {
                let note = Note()
                note.id = meeting.id
                note.title = meeting.title
                note.titleIsCustom = meeting.titleIsCustom
                note.createdAt = meeting.createdAt
                note.updatedAt = meeting.createdAt
                note.duration = meeting.duration
                note.statusRaw = meeting.statusRaw
                note.errorMessage = meeting.errorMessage
                note.inputName = meeting.inputName
                note.channelCount = meeting.channelCount
                note.speakerModeRaw = meeting.speakerModeRaw
                note.audioFileName = meeting.audioFileName
                note.speakersData = meeting.speakersData
                note.segmentsData = meeting.segmentsData
                note.summary = meeting.summary
                note.summaryModel = meeting.summaryModel
                note.summarizedAt = meeting.summarizedAt
                context.insert(note)
            }
            meeting.migrated = true
        }
        try? context.save()
    }

    /// Two devices may copy the same meeting at the same time; keep one note per id.
    static func removeDuplicates(in context: ModelContext) {
        let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []
        var seen = Set<UUID>()
        var removed = false
        for note in notes.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if !seen.insert(note.id).inserted {
                context.delete(note)
                removed = true
            }
        }
        if removed { try? context.save() }
    }
}
