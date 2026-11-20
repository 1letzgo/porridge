#if DEBUG
import Foundation
import SwiftData

/// Data for the UI tests, only in debug builds: `-seedMeetingWithTasks <title>` adds a summarized meeting whose
/// summary has three tasks (the user's, somebody else's with a date, nobody's), in a new bucket of the same name.
/// `-seedTodos <prefix>` adds four open to-dos: "<prefix> long overdue" (due 1 January 2000, in a new bucket named
/// <prefix>), "<prefix> today", "<prefix> upcoming" (in five days) and "<prefix> no date".
enum TestSeed {
    @MainActor
    static func run(_ container: ModelContainer) {
        seedTodos(container)
        guard let title = UserDefaults.standard.string(forKey: "seedMeetingWithTasks"), !title.isEmpty else { return }
        let context = container.mainContext
        let bucket = NoteFolder(name: title)
        context.insert(bucket)
        let meeting = Note()
        meeting.title = title
        meeting.titleIsCustom = true
        meeting.source = .meeting
        meeting.segments = [TranscriptSegment(start: 0, end: 5, text: "Let's wrap up.")]
        meeting.projectIDs = [Projects.key(bucket)]
        meeting.filedAt = Date()
        let due = Todos.dueKey(Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date())
        meeting.summary = """
        ## Summary
        The team planned the launch.

        ## Action Items
        - [ ] Send the offer to the customer – \(AppSettings.myName ?? "Me")
        - [ ] Book the venue – Anna – \(due)
        - [ ] Update the roadmap
        """
        meeting.summaryModel = "Test"
        meeting.summarizedAt = Date()
        TodoSuggestions.offer(meeting)
        context.insert(meeting)
        try? context.save()
        UserDefaults.standard.removeObject(forKey: "seedMeetingWithTasks")
    }

    @MainActor
    private static func seedTodos(_ container: ModelContainer) {
        guard let prefix = UserDefaults.standard.string(forKey: "seedTodos"), !prefix.isEmpty else { return }
        let context = container.mainContext
        let bucket = NoteFolder(name: prefix)
        context.insert(bucket)
        let today = Date()
        let soon = Calendar.current.date(byAdding: .day, value: 5, to: today) ?? today
        for (name, due) in [("long overdue", "2000-01-01"), ("today", Todos.dueKey(today)), ("upcoming", Todos.dueKey(soon)), ("no date", nil)] {
            let todo = Note()
            todo.title = "\(prefix) \(name)"
            todo.titleIsCustom = true
            todo.source = .note
            todo.todoState = .open
            todo.todoDueDay = due
            if due == "2000-01-01" {
                todo.projectIDs = [Projects.key(bucket)]
                todo.filedAt = today
            }
            context.insert(todo)
        }
        try? context.save()
    }

    /// The entries of `ChatDataTests` as real notes, for trying the chat by hand (debug driver `seed-chat` on the
    /// Mac): three buckets "Reisen", "Haus und Garten", "Arbeit" and 15 entries of every kind, dated around Friday,
    /// 20 November 2026. Only on test data (`DataLocation.testFolder`), never in the real store.
    @MainActor
    static func seedChat(_ context: ModelContext) {
        guard DataLocation.testFolder != nil else { return }
        let calendar = Calendar.current
        func day(_ day: Int, month: Int = 11, hour: Int = 10) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
        }
        var keys: [String: String] = [:]
        for name in ["Reisen", "Haus und Garten", "Arbeit"] {
            let bucket = NoteFolder(name: name)
            context.insert(bucket)
            keys[name] = Projects.key(bucket)
        }
        let travel = keys["Reisen"]!, house = keys["Haus und Garten"]!, work = keys["Arbeit"]!
        func add(_ title: String, text: String = "", created: Date, buckets: [String] = [], configure: (Note) -> Void = { _ in }) {
            let note = Note()
            note.title = title
            note.titleIsCustom = true
            note.text = text
            note.createdAt = created
            note.updatedAt = created
            note.projectIDs = buckets
            if !buckets.isEmpty { note.filedAt = created }
            configure(note)
            context.insert(note)
        }
        add("Packliste Norwegen", text: "Regenjacke, Wanderschuhe und Fleece einpacken.", created: day(10), buckets: [travel])
        add("Kickoff Website", created: day(17), buckets: [work]) { note in
            note.source = .meeting
            note.audioFileName = "kickoff.m4a"
            note.speakers = [Speaker(id: "A", name: "Anna", colorIndex: 0), Speaker(id: "B", name: "Ben", colorIndex: 1)]
            note.segments = [
                TranscriptSegment(speakerId: "A", start: 0, end: 5, text: "Wir haben beschlossen, das Budget auf 20.000 Euro festzulegen."),
                TranscriptSegment(speakerId: "B", start: 5, end: 9, text: "Der Launch ist im Februar."),
            ]
            note.summary = "Beschlüsse: Budget 20.000 Euro. Launch im Februar."
            note.statusRaw = ProcessingStatus.ready.rawValue
        }
        add("Weekly", created: day(10), buckets: [work]) { note in
            note.source = .meeting
            note.audioFileName = "weekly.m4a"
            note.segments = [TranscriptSegment(start: 0, end: 5, text: "Die Entscheidung über das Logo verschieben wir.")]
            note.statusRaw = ProcessingStatus.ready.rawValue
        }
        add("Swift Concurrency Guide", created: day(18)) { note in
            note.url = "https://www.swift.org/documentation/concurrency"
            note.pageText = "Swift concurrency uses async and await. Actors protect mutable state."
        }
        add("Sauerteig Rezept", created: day(5), buckets: [house]) { note in
            note.url = "https://example.com/sauerteig"
            note.pageText = "Sauerteig braucht Roggenmehl, Wasser und viel Zeit."
        }
        add("Kotlin Coroutines", created: day(1), buckets: [work]) { note in
            note.url = "https://kotlinlang.org/docs/coroutines-overview.html"
            note.pageText = "Coroutines make asynchronous programming in Kotlin simple."
        }
        add("Angebot an Müller schicken", created: day(1), buckets: [work]) { note in
            note.todoState = .open
            note.todoDueDay = "2026-11-19"
        }
        add("Hecke schneiden", text: "- [x] Schere schärfen\n- [ ] Grünschnitt wegbringen", created: day(12), buckets: [house]) { note in
            note.todoState = .open
            note.todoDueDay = "2026-11-22"
        }
        add("Steuererklärung", created: day(2)) { note in
            note.todoState = .open
            note.todoDueDay = "2026-12-10"
        }
        add("Fahrrad reparieren", text: "Schlauch hinten tauschen.", created: day(3), buckets: [house]) { note in
            note.todoState = .open
        }
        add("Fährtickets buchen", created: day(4), buckets: [travel]) { note in
            note.todoState = .done
            note.todoDueDay = "2026-11-18"
            note.todoDoneAt = day(18, hour: 9)
        }
        add("Whiteboard", created: day(19), buckets: [work]) { note in
            note.source = .share
            note.attachments = [Attachment(fileName: "w.jpg", name: "IMG_0042.jpg", kindRaw: "image")]
            note.pageText = "Roadmap Q1: Login, Payments, Export"
        }
        add("Mietvertrag", created: day(1, month: 10), buckets: [house]) { note in
            note.source = .share
            note.attachments = [Attachment(fileName: "m.pdf", name: "Mietvertrag.pdf", kindRaw: "pdf")]
            note.pageText = "Die Kaution beträgt 2.400 Euro und wird auf ein Sparbuch gezahlt."
        }
        add("Geheimes Projekt", text: "Codename Falke startet im Frühjahr.", created: day(15)) { note in
            note.deletedAt = day(16)
        }
        add("Altes Rezept", text: "Pfannkuchen mit Milch, Mehl und Eiern.", created: day(1, month: 3)) { note in
            note.archivedAt = day(1, month: 4)
        }
        try? context.save()
    }
}
#endif
