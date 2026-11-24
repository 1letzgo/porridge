#if os(iOS)
import AppIntents
import Foundation
import WidgetKit

/// Puts text into the inbox without opening the app. It goes the way of the share sheet (`ShareInbox`): the app
/// takes it in as a note when it runs next, at once when it is open.
struct AddToInboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Porridge Inbox"
    static let description = IntentDescription("Puts a note into the Porridge inbox without opening the app.")
    static let openAppWhenRun = false

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true), requestValueDialog: "What should go into the inbox?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to the Porridge inbox")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .result(dialog: "Nothing to add.") }
        try await MainActor.run { try WidgetSync.addToInbox(trimmed) }
        await MainActor.run { NotificationCenter.default.post(name: .porridgeShareInboxChanged, object: nil) }
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetStore.Kind.inbox)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetStore.Kind.inboxCount)
        return .result(dialog: "Added to your inbox.")
    }
}

/// The titles of the open to-dos, due ones first: from the copy the app keeps for its widgets (`WidgetSnapshot`),
/// so it works without opening the app.
struct GetOpenTodosIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Open To-dos"
    static let description = IntentDescription("Returns the titles of your open to-dos in Porridge, overdue and due first.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let titles = Self.titles(WidgetStore.snapshot(), pending: WidgetStore.pendingCompletions())
        let dialog: IntentDialog = titles.isEmpty
            ? "You have no open to-dos."
            : titles.count == 1 ? "You have 1 open to-do: \(titles[0])." : "You have \(titles.count) open to-dos."
        return .result(value: titles, dialog: dialog)
    }

    /// Open to-dos by due day; those ticked in a widget and not yet taken in are left out.
    static func titles(_ snapshot: WidgetSnapshot?, pending: [WidgetStore.Completion]) -> [String] {
        guard let snapshot else { return [] }
        let ticked = Set(pending.map(\.id))
        return snapshot.todos.filter { !ticked.contains($0.id) }.map(\.title)
    }
}

/// Opens the search with what to look for.
struct SearchPorridgeIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Porridge"
    static let description = IntentDescription("Opens Porridge and searches your notes, meetings and links.")
    static let openAppWhenRun = true

    @Parameter(title: "Search For", requestValueDialog: "What are you looking for?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Search Porridge for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionCenter.request(.search(query))
        return .result()
    }
}

/// Opens the inbox.
struct OpenInboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Inbox"
    static let description = IntentDescription("Opens the Porridge inbox.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionCenter.request(.openInbox)
        return .result()
    }
}

/// Opens Today.
struct OpenTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Today"
    static let description = IntentDescription("Opens Today in Porridge: the day's appointments and the to-dos due.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionCenter.request(.openToday)
        return .result()
    }
}

/// Opens the Bowls place.
struct OpenBowlsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Bowls"
    static let description = IntentDescription("Opens your bowls in Porridge.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        QuickActionCenter.request(.openBowls)
        return .result()
    }
}
#endif
