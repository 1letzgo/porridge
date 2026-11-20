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
}
#endif
