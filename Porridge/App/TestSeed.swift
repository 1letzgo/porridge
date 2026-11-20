#if DEBUG
import Foundation
import SwiftData

/// Data for the UI tests, only in debug builds: `-seedMeetingWithTasks <title>` adds a summarized meeting whose
/// summary has three tasks (the user's, somebody else's with a date, nobody's), in a new bucket of the same name.
enum TestSeed {
    @MainActor
    static func run(_ container: ModelContainer) {
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
}
#endif
