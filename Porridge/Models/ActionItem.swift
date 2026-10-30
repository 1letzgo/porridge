import Foundation
import SwiftData

/// A task or a decision taken out of a note's summary, so it can be ticked off and asked for across all
/// meetings. Ticking an item also ticks its line in the summary (see `ActionItems`).
/// CloudKit-compatible: every property has a default, the note is referenced by id.
@Model
final class ActionItem {
    var id: UUID = UUID()
    /// `Note.id` of the note the item comes from.
    var noteID: UUID?
    var kindRaw: String = Kind.task.rawValue
    var text: String = ""
    /// Who is responsible, when the summary says ("Task – Anna").
    var owner: String?
    var isDone: Bool = false
    var doneAt: Date?
    var createdAt: Date = Date()
    /// Position in the summary, so the order stays the same everywhere.
    var order: Int = 0
    /// Where the item comes from: "summary" (kept in step with the summary) or "manual".
    var source: String = "summary"

    enum Kind: String {
        case task
        case decision
    }

    init() {
        self.id = UUID()
    }

    var kind: Kind {
        get { Kind(rawValue: kindRaw) ?? .task }
        set { kindRaw = newValue.rawValue }
    }

    var isFromSummary: Bool { source == "summary" }

    /// The text with the owner, as it stands in the summary.
    var line: String {
        owner.map { "\(text) – \($0)" } ?? text
    }
}
