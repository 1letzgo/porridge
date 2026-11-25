import Foundation

/// The commands of the Entry and AI menus and the toolbar's ✦ AI and ⋯ menus that need the entry's page: they open a
/// sheet there or change what it shows. The menu items carry the raw value as their tag (raw values are kept: new
/// cases go at the end).
enum NoteCommand: Int, CaseIterable {
    case summarize = 1
    case enhance
    case undoEnhance
    case editSummary
    case insertSummary
    case copySummary
    case deleteSummary
    case continueRecording
    case merge
    case export
    case deleteRecording
    case loadPageAgain
    case dictate
    case addTag
    case toggleTodo
    case convertTodo
    case showSummary
    case showNote
    case showTranscript
    case showArticle
    case suggestTodos
    case splitIntoBowl
    // Stage 3: Entry › Appointment, Document, Pages; the toolbar's short More.
    // 23 was Later › Back to Inbox Now (removed with Later, owner revision 9).
    /// Appointment › Remove Appointment.
    case removeAppointment = 24
    /// Document › Set Sender…
    case setSender
    // 26 was Document › Mark as Paid (removed: documents keep no payment status).
    /// Document › Edit Details…
    case editDocument = 27
    /// Pages › Edit Pages… (also ⋯ More).
    case editPages
    /// Pages › Add Pages › From a File…
    case addPagesFromFile
    /// ⋯ More of a link.
    case openInBrowser
    case copyLink
    /// Entry › Save as Template… (also ⋯ More).
    case saveAsTemplate
    /// ⋯ More of a view-only entry: its text (or summary, or transcript).
    case copyText
}
