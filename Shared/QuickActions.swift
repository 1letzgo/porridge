import Foundation
#if os(iOS)
import AppIntents
import WidgetKit
#endif

/// What a widget, a control, a shortcut or a `porridge://` link asks the app to do when it opens.
enum QuickAction: Equatable {
    case newNote
    case startMeeting
    case openInbox
    case openTodos
    /// The search page with this query.
    case search(String)
    /// One entry (`Note.id`): `porridge://entry/<id>`, the form of the links between entries.
    case openNote(UUID)

    static let scheme = PorridgeURL.scheme

    /// The link that asks for this action: `porridge://new`, `porridge://meeting`, `porridge://inbox`,
    /// `porridge://todos`, `porridge://search?q=…`, `porridge://entry/<id>` (`porridge://note/<id>` is read too).
    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .newNote: components.host = "new"
        case .startMeeting: components.host = "meeting"
        case .openInbox: components.host = "inbox"
        case .openTodos: components.host = "todos"
        case .search(let query):
            components.host = "search"
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        case .openNote(let id):
            return PorridgeURL.entry(id)
        }
        return components.url!
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch components.host?.lowercased() {
        case "new": self = .newNote
        case "meeting": self = .startMeeting
        case "inbox": self = .openInbox
        case "todos": self = .openTodos
        case "search":
            self = .search(components.queryItems?.first { $0.name == "q" }?.value ?? "")
        case PorridgeURL.entryHost, "note":
            let parts = url.path.split(separator: "/")
            guard parts.count == 1, let id = UUID(uuidString: String(parts[0])) else { return nil }
            self = .openNote(id)
        default: return nil
        }
    }
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

/// The box of a to-do in the To-dos widget. It runs where the system runs it: in the widget extension it queues the
/// tick for the app (`WidgetStore`); in the app with its list on screen it is applied at once (`WidgetBridge`).
/// Either way the app applies it with `Todos.setDone`, so repeat rules and view-only bowls are kept.
struct CompleteTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete To-do"
    static let isDiscoverable = false

    /// `Note.id` as uppercase string.
    @Parameter(title: "To-do")
    var todoID: String

    /// The due day the widget showed ("yyyy-MM-dd"), empty without one.
    @Parameter(title: "Due Day")
    var due: String

    init() {}

    init(todoID: String, due: String?) {
        self.todoID = todoID
        self.due = due ?? ""
    }

    func perform() async throws -> some IntentResult {
        let completion = WidgetStore.Completion(id: todoID, due: due.isEmpty ? nil : due)
        let applied = await MainActor.run { WidgetBridge.complete?(completion) ?? false }
        if !applied {
            WidgetStore.queueCompletion(completion)
            WidgetStore.notifyApp()
        }
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetStore.Kind.todos)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetStore.Kind.todoCount)
        return .result()
    }
}
#endif
