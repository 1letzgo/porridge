#if os(iOS)
import AppIntents

/// The quick actions for Siri, Spotlight, the Shortcuts app and the Action button.
struct PorridgeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartMeetingIntent(),
            phrases: ["Start a meeting in \(.applicationName)", "Record a meeting with \(.applicationName)"],
            shortTitle: "Start Meeting",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: NewNoteIntent(),
            phrases: ["New note in \(.applicationName)", "Write a note in \(.applicationName)"],
            shortTitle: "New Note",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: AddToInboxIntent(),
            phrases: ["Add to \(.applicationName) inbox", "Add to my \(.applicationName) inbox", "Capture in \(.applicationName)"],
            shortTitle: "Add to Inbox",
            systemImageName: "tray.and.arrow.down"
        )
        AppShortcut(
            intent: GetOpenTodosIntent(),
            phrases: ["Get open to-dos from \(.applicationName)", "What are my to-dos in \(.applicationName)", "Show my \(.applicationName) to-dos"],
            shortTitle: "Open To-dos",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: SearchPorridgeIntent(),
            phrases: ["Search \(.applicationName)", "Search in \(.applicationName)"],
            shortTitle: "Search",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: OpenTodayIntent(),
            phrases: ["Open \(.applicationName) today", "Open Today in \(.applicationName)"],
            shortTitle: "Open Today",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: OpenBowlsIntent(),
            phrases: ["Open \(.applicationName) bowls", "Open my bowls in \(.applicationName)"],
            shortTitle: "Open Bowls",
            systemImageName: "folder.fill"
        )
        AppShortcut(
            intent: OpenInboxIntent(),
            phrases: ["Open \(.applicationName) inbox", "Open my inbox in \(.applicationName)"],
            shortTitle: "Open Inbox",
            systemImageName: "tray.fill"
        )
    }
}
#endif
