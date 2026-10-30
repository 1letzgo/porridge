import Foundation
import SwiftData

/// A task (or a decision) of its own: title, owner, done, and its own text. Most come out of a note's
/// summary (`noteID` says which, as the place it was born); they can be renamed and written into freely and
/// stay when their line or note goes. Ticking an item also ticks its line in the summary (see `ActionItems`).
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
    /// Where the item comes from: "summary" (kept in step with the summary), "manual" (typed by hand) or
    /// "kept" (came from a summary, was edited, and lives on its own since its line is gone).
    var source: String = "summary"
    /// The task's own text (Markdown, like a note's body): details, links, sub-steps.
    var details: String = ""
    /// The summary line the item was made from (`ActionItems.key`); stays when the task is renamed, so the
    /// summary still finds it. Nil for tasks typed by hand.
    var summaryKey: String?
    var updatedAt: Date = Date()
    /// Whether a task the summary brought in was looked at (`Review`). Items from before there was a review
    /// count as accepted.
    var reviewRaw: String = Review.accepted.rawValue

    enum Kind: String {
        case task
        case decision
    }

    /// A task out of a summary is a suggestion first: it waits under "New" until it is taken on or dropped.
    enum Review: String {
        case pending
        case accepted
        /// Dropped: hidden everywhere, but kept so its summary line does not bring it back.
        case dismissed
    }

    init() {
        self.id = UUID()
    }

    var kind: Kind {
        get { Kind(rawValue: kindRaw) ?? .task }
        set { kindRaw = newValue.rawValue }
    }

    var review: Review {
        get { Review(rawValue: reviewRaw) ?? .accepted }
        set { reviewRaw = newValue.rawValue }
    }

    var isFromSummary: Bool { source == "summary" }

    /// New out of a summary and not looked at yet (a ticked one needs no review).
    var needsReview: Bool { review == .pending && !isDone }

    /// The text with the owner, as it stands in the summary.
    var line: String {
        owner.map { "\(text) – \($0)" } ?? text
    }
}
