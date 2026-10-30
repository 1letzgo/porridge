import Foundation
#if os(iOS)
import AppIntents
#endif

/// What a widget, a control or a shortcut asks the app to do when it opens.
enum QuickAction: String {
    case newNote
    case startMeeting
}

extension Notification.Name {
    static let porridgeQuickAction = Notification.Name("de.letzgo.porridge.quickAction")
}

/// Holds the action until the list is on screen: on a cold launch the intent runs before any view exists.
@MainActor
enum QuickActionCenter {
    private static var pending: QuickAction?

    static func request(_ action: QuickAction) {
        pending = action
        NotificationCenter.default.post(name: .porridgeQuickAction, object: nil)
    }

    /// The waiting action, handed out once.
    static func take() -> QuickAction? {
        defer { pending = nil }
        return pending
    }
}

#if os(iOS)
/// Opens Porridge with a new note. Part of the app and the widget extension, so it runs in the app.
struct NewNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Note"
    static let description = IntentDescription("Opens Porridge with a new note.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionCenter.request(.newNote)
        return .result()
    }
}

/// Opens Porridge and starts recording a meeting.
struct StartMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Meeting"
    static let description = IntentDescription("Opens Porridge and starts recording a meeting.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionCenter.request(.startMeeting)
        return .result()
    }
}
#endif
