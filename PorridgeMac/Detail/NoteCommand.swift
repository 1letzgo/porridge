import Foundation

/// The commands of the Note menu and the toolbar's More menu that need the note's page: they open a sheet there
/// or change what it shows. The menu items carry the raw value as their tag.
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
}
