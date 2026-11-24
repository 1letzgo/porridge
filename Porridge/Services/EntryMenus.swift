import Foundation

/// The three buttons of an entry, by verb (iPhone head capsule, Mac toolbar): ✦ AI, Share and ⋯ More, with the exact
/// contents per kind of the design's table (HTML 3.1). Groups are separated by a divider. Only what applies is
/// listed; whether an item can be used right now (a selection for Rewrite, a model for Summarize) is the view's
/// business. Hard rules: a link never gets Suggest To-dos; Recently Deleted gets only Recover and Delete Now; an
/// entry in a bowl shared with me to view only gets Pin, Copy and Save as Template (and Ask About This Bowl).
@MainActor
enum EntryMenus {
    enum Platform {
        case iPhone, mac

        static var current: Platform {
            #if os(macOS)
            .mac
            #else
            .iPhone
            #endif
        }
    }

    enum AIItem: Equatable {
        case enhance
        case undoEnhance
        /// "Summarize…", or "Summarize Again…" when there is a summary.
        case summarize(again: Bool)
        case suggestTodos
        case rewriteSelection
        case splitIntoBowl
        case askAboutBowl

        var title: String {
            switch self {
            case .enhance: String(localized: "Enhance with AI…")
            case .undoEnhance: String(localized: "Undo Enhance")
            case .summarize(let again): again ? String(localized: "Summarize Again…") : String(localized: "Summarize…")
            case .suggestTodos: String(localized: "Suggest To-dos")
            case .rewriteSelection: String(localized: "Rewrite Selection…")
            case .splitIntoBowl: String(localized: "Split into Bowl…")
            case .askAboutBowl: String(localized: "Ask About This Bowl")
            }
        }

        /// The symbol of the item, the same on the iPhone and the Mac.
        var systemImage: String {
            switch self {
            case .enhance: "wand.and.stars"
            case .undoEnhance: "arrow.uturn.backward"
            case .summarize: "sparkles"
            case .suggestTodos: "checklist"
            case .rewriteSelection: "pencil.line"
            case .splitIntoBowl: "square.split.2x2"
            case .askAboutBowl: "bubble.left.and.bubble.right"
            }
        }
    }

    /// What Share hands over, one per kind.
    enum ShareItem: Equatable {
        /// The system share sheet with the text as Markdown (notes, mails, shared text).
        case markdown
        /// The system share sheet with the text and its subtasks.
        case todoText
        /// The export sheet (summary / transcript, format) of a meeting.
        case exportSheet
        /// The system share sheet with the link's address.
        case url
        case image
        case file
    }

    enum MoreItem: Equatable {
        /// "Pin" or "Unpin".
        case pin
        /// "Mark as Done" or "Mark as Not Done".
        case markDone
        case convertToTodo
        case convertToNote
        /// Later ▸, for an entry in the Inbox.
        case later
        /// "Mark as Paid" or "Mark as Unpaid", for a document that asks for payment.
        case markPaid
        case editPages
        /// iPhone only: the scanner adds pages to the PDF.
        case scanMorePages
        case openInBrowser
        case copyLink
        case loadPageAgain
        // Recording
        case continueRecording
        case transcribeAgain
        case mergeWith
        case copyTranscript
        case deleteRecording
        case saveAsTemplate
        /// View-only entries: their text (the summary or transcript when there is no text).
        case copy
        /// The Mac: the entry in a window of its own.
        case openInNewWindow
        case delete
        // Recently Deleted
        case recover
        case deleteNow

        /// The title for this note's state (Pin / Unpin, Mark as Done / Not Done, Mark as Paid / Unpaid).
        func title(for note: Note) -> String {
            switch self {
            case .pin: note.isPinned ? String(localized: "Unpin") : String(localized: "Pin")
            case .markDone: note.isDone ? String(localized: "Mark as Not Done") : String(localized: "Mark as Done")
            case .convertToTodo: String(localized: "Convert to To-do")
            case .convertToNote: String(localized: "Convert to Note")
            case .later: String(localized: "Later")
            case .markPaid: note.documentInfo?.paid == true ? String(localized: "Mark as Unpaid") : String(localized: "Mark as Paid")
            case .editPages: String(localized: "Edit Pages…")
            case .scanMorePages: String(localized: "Scan More Pages")
            case .openInBrowser: String(localized: "Open in Browser")
            case .copyLink: String(localized: "Copy Link")
            case .loadPageAgain: String(localized: "Load Page Again")
            case .continueRecording: String(localized: "Continue Recording")
            case .transcribeAgain: String(localized: "Transcribe Again")
            case .mergeWith: String(localized: "Merge with…")
            case .copyTranscript: String(localized: "Copy Transcript")
            case .deleteRecording: String(localized: "Delete Recording…")
            case .saveAsTemplate: String(localized: "Save as Template…")
            case .copy: String(localized: "Copy")
            case .openInNewWindow: String(localized: "Open in New Window")
            case .delete: String(localized: "Delete")
            case .recover: String(localized: "Recover")
            case .deleteNow: String(localized: "Delete Now…")
            }
        }

        /// The symbol for this note's state, the same on the iPhone and the Mac.
        func systemImage(for note: Note) -> String {
            switch self {
            case .pin: note.isPinned ? "pin.slash" : "pin"
            case .markDone: note.isDone ? "square" : "checkmark.square"
            case .convertToTodo: "checklist"
            case .convertToNote: "text.alignleft"
            case .later: "clock"
            case .markPaid: note.documentInfo?.paid == true ? "creditcard" : "checkmark.circle"
            case .editPages: "doc.on.doc"
            case .scanMorePages: "doc.viewfinder"
            case .openInBrowser: "safari"
            case .copyLink: "link"
            case .loadPageAgain: "arrow.clockwise"
            case .continueRecording: "mic.badge.plus"
            case .transcribeAgain: "waveform"
            case .mergeWith: "arrow.triangle.merge"
            case .copyTranscript: "doc.on.doc"
            case .deleteRecording: "waveform.slash"
            case .saveAsTemplate: "doc.badge.plus"
            case .copy: "doc.on.doc"
            case .openInNewWindow: "macwindow"
            case .delete: "trash"
            case .recover: "arrow.uturn.backward"
            case .deleteNow: "trash"
            }
        }

        /// Deletes or takes something away: drawn red.
        var isDestructive: Bool {
            self == .delete || self == .deleteNow || self == .deleteRecording
        }
    }

    // MARK: ✦ AI

    /// Groups of the AI menu: what the model does to this entry, then Ask About This Bowl. Empty in Recently Deleted.
    static func ai(for note: Note, context: EntryContext) -> [[AIItem]] {
        if note.isDeleted { return [] }
        let ask: [AIItem] = isInBowl(note) ? [.askAboutBowl] : []
        if context.isReadOnly { return ask.isEmpty ? [] : [ask] }
        var main: [AIItem]
        switch EntryKind(note) {
        case .note:
            main = [.enhance]
            if context.canUndoEnhance { main.append(.undoEnhance) }
            if note.summary != nil {
                // A note summarized earlier keeps its way to the summary's tasks (the old menus had it too).
                main += [.summarize(again: true), .suggestTodos]
            }
            main += [.rewriteSelection, .splitIntoBowl]
        case .todo:
            main = [.enhance]
            if context.canUndoEnhance { main.append(.undoEnhance) }
            main += [.rewriteSelection, .splitIntoBowl]
        case .meeting:
            main = [.summarize(again: note.summary != nil), .suggestTodos, .splitIntoBowl]
        case .link, .image, .document:
            // Never Suggest To-dos: saved things produce no tasks.
            main = [.summarize(again: note.summary != nil)]
        }
        return [main, ask].filter { !$0.isEmpty }
    }

    // MARK: Share

    /// What Share hands over; nothing in Recently Deleted.
    static func share(for note: Note) -> ShareItem? {
        if note.isDeleted { return nil }
        switch EntryKind(note) {
        case .note: return .markdown
        case .todo: return .todoText
        case .meeting: return .exportSheet
        case .link: return .url
        case .image: return .image
        case .document: return .file
        }
    }

    // MARK: ⋯ More

    /// Groups of the More menu: organize, then (meetings) Recording, then Save as Template, then Delete. The Mac adds
    /// Open in New Window before Delete.
    static func more(for note: Note, context: EntryContext, platform: Platform = .current) -> [[MoreItem]] {
        if note.isDeleted { return [[.recover, .deleteNow]] }
        if context.isReadOnly {
            var groups: [[MoreItem]] = [[.pin, .copy, .saveAsTemplate]]
            if platform == .mac { groups.append([.openInNewWindow]) }
            return groups
        }
        let kind = EntryKind(note)
        var organize: [MoreItem] = [.pin]
        if note.isTodo { organize.append(.markDone) }
        switch kind {
        case .link:
            organize += [.openInBrowser, .copyLink, .loadPageAgain]
        case .image:
            if offersPaid(note) { organize.append(.markPaid) }
        case .document:
            if offersPaid(note) { organize.append(.markPaid) }
            if DocumentFiles.pdf(of: note) != nil {
                organize.append(.editPages)
                if platform == .iPhone { organize.append(.scanMorePages) }
            }
        case .note, .todo, .meeting:
            break
        }
        // Into a to-do and back where the entry may be one (`Note.canBeTodo`).
        if note.isTodo {
            organize.append(.convertToNote)
        } else if note.canBeTodo {
            organize.append(.convertToTodo)
        }
        if note.isInInbox { organize.append(.later) }

        var groups = [organize]
        if kind == .meeting {
            groups.append([.continueRecording, .transcribeAgain, .mergeWith, .copyTranscript, .deleteRecording])
        }
        if kind == .note || kind == .todo || kind == .meeting { groups.append([.saveAsTemplate]) }
        if platform == .mac { groups.append([.openInNewWindow]) }
        groups.append([.delete])
        return groups
    }

    // MARK: What Share and Copy hand over

    /// The file Share hands over for an image or a document, when it is on this device; nil otherwise (then the
    /// text goes).
    static func shareFile(for note: Note) -> URL? {
        let kind = EntryKind(note)
        guard kind == .image || kind == .document else { return nil }
        let attachments = note.attachments
        let file = kind == .image
            ? attachments.first { $0.kind == .image }
            : DocumentFiles.pdf(of: note) ?? attachments.first { $0.kind != .image } ?? attachments.first
        guard let file, AttachmentStore.exists(file) else { return nil }
        return AttachmentStore.url(for: file)
    }

    /// What "Copy" of a view-only entry puts on the clipboard: its text, else its summary, else its transcript.
    static func copyText(for note: Note) -> String {
        let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return note.exportText }
        if let summary = note.summary, !summary.isEmpty { return summary }
        if !note.segments.isEmpty { return note.transcriptText() }
        return note.exportText
    }

    // MARK: Helpers

    /// In a bowl (not the Inbox): it can be asked about.
    private static func isInBowl(_ note: Note) -> Bool { !note.projectIDs.isEmpty }

    /// A document that asks for payment, or whose payment is followed (`DocumentInfo.offersPaid`).
    private static func offersPaid(_ note: Note) -> Bool {
        note.isDocument && note.documentInfo?.offersPaid == true
    }
}
