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
    }
}
#endif
