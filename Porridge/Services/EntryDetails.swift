import Foundation

/// What an entry's head, its Details and its menus need to know besides the note itself: the bowls (for names),
/// whether it may be changed here, its appointment, the latest change by someone else. One value, read once per
/// render, so the head (`EntryMeta`), Details (`EntryDetails`) and the menus (`EntryMenus`) agree on iPhone and Mac.
/// Tests build it by hand; the apps take `live(for:bowls:)`.
struct EntryContext {
    /// The bowls the app knows (archived ones included), for names and suggestions.
    var bowls: [NoteFolder] = []
    /// In a bowl shared with me to view only (`BowlSharing.isReadOnly`).
    var isReadOnly = false
    /// The bowl it is in is shared (by me or with me).
    var isInSharedBowl = false
    /// The appointment the entry is linked to (`AppointmentLinks`).
    var appointment: AppointmentRef?
    /// "Changed by Anna": what someone else did to it and this device has not shown yet (`BowlSharing.activityLine`).
    var activityLine: String?
    /// The text is still the one of its last enhance, so "Undo Enhance" applies (`ProcessingService.canUndoEnhance`).
    var canUndoEnhance = false
    /// Pages of its PDF, when the view knows them (counting needs the file).
    var pageCount: Int?
    var now = Date()

    /// The state of the running app for this note.
    @MainActor
    static func live(for note: Note, bowls: [NoteFolder], processing: ProcessingService? = nil, now: Date = Date()) -> EntryContext {
        let sharing = BowlSharing.shared
        return EntryContext(
            bowls: bowls,
            isReadOnly: !note.isDeleted && sharing.isReadOnly(note),
            isInSharedBowl: note.projectIDs.contains { sharing.isShared(UUID(uuidString: $0)) },
            appointment: AppointmentLinks.shared.appointment(for: note.id),
            activityLine: sharing.activityLine(for: note),
            canUndoEnhance: processing?.canUndoEnhance(note) ?? false,
            now: now
        )
    }

    /// The bowl of that key (`Projects.key`).
    func bowl(_ key: String) -> NoteFolder? {
        bowls.first { Projects.key($0) == key }
    }
}

/// What an entry is, for its menus and its Details: the kinds of the design's table (HTML 3.1). A link, an image
/// and a stored file are what they hold; a recording is a meeting (imported audio too); a note is a to-do when it
/// is one.
enum EntryKind: Equatable {
    case note, todo, meeting, link, image, document

    init(_ note: Note) {
        if note.isLink {
            self = .link
        } else if note.isImage {
            self = .image
        } else if note.isFile {
            self = .document
        } else if note.isRecording {
            self = .meeting
        } else if note.isTodo {
            self = .todo
        } else {
            self = .note
        }
    }
}

/// The Details panel (iPhone sheet, Mac inspector): its sections in their fixed order and the rows of each. Only
/// what is shown where; the views fill in the values and the controls. A section is left out only where it makes
/// no sense for the kind (Document only for stored files, Speakers only for recordings); an empty value inside a
/// section is shown as "None" by the view.
@MainActor
enum EntryDetails {
    struct Section: Identifiable, Equatable {
        enum Kind: String, CaseIterable {
            case organize, appointment, document, speakers, connections, sharingActivity

            var title: String {
                switch self {
                case .organize: String(localized: "Organize")
                case .appointment: String(localized: "Appointment")
                case .document: String(localized: "Document")
                case .speakers: String(localized: "Speakers")
                case .connections: String(localized: "Connections")
                case .sharingActivity: String(localized: "Sharing & Activity")
                }
            }
        }

        /// The button in a section's header.
        enum Action: Equatable {
            /// Appointment: link another one, or one at all ("Change…").
            case changeAppointment
            /// Document of a PDF: the pages sheet.
            case editPages
            /// Speakers: the people the app knows by voice.
            case knownVoices
        }

        let kind: Kind
        let rows: [Row]
        var action: Action?

        var id: Kind { kind }
    }

    struct Row: Identifiable, Equatable {
        enum Kind: String, Equatable {
            // Organize
            /// The kind's name and the to-do switch (`canSwitchTodo`).
            case type
            case bowl
            /// The bowl suggested for an entry in the Inbox, with "File".
            case suggestedBowl
            case due
            case `repeat`
            case tags
            // Appointment
            case appointment
            /// The other entries of the same appointment ("2 more entries").
            case sameAppointment
            // Document
            case documentKind
            case sender
            case dated
            case amount
            // Speakers
            case speakers
            // Connections
            case linkedFrom
            case similar
            // Sharing & Activity
            case sharing
            case activity
            /// Where a recording was made ("This iPhone · Microphone"), or where an entry came in from.
            case origin
        }

        let kind: Kind
        /// Nothing can be changed here: the entry is in Recently Deleted, or in a bowl shared with me to view only.
        let isLocked: Bool

        var id: Kind { kind }
    }

    /// The sections of one entry, in the fixed order Organize · Appointment · Document · Speakers · Connections ·
    /// Sharing & Activity.
    static func sections(for note: Note, context: EntryContext) -> [Section] {
        let locked = note.isDeleted || context.isReadOnly
        func rows(_ kinds: [Row.Kind]) -> [Row] { kinds.map { Row(kind: $0, isLocked: locked) } }

        var organize: [Row.Kind] = [.type, .bowl]
        if suggestion(for: note, context: context) != nil { organize.append(.suggestedBowl) }
        if note.isTodo { organize += [.due, .repeat] }
        organize.append(.tags)

        var result = [Section(kind: .organize, rows: rows(organize))]

        var appointment: [Row.Kind] = [.appointment]
        if context.appointment != nil { appointment.append(.sameAppointment) }
        result.append(Section(kind: .appointment, rows: rows(appointment), action: locked ? nil : .changeAppointment))

        if note.isStored {
            var document: [Row.Kind] = [.documentKind, .sender, .dated]
            let info = note.documentInfo ?? DocumentInfo()
            if info.kind?.hasAmount ?? true { document.append(.amount) }
            let pages = !locked && DocumentFiles.pdf(of: note) != nil
            result.append(Section(kind: .document, rows: rows(document), action: pages ? .editPages : nil))
        }

        if note.isRecording {
            result.append(Section(kind: .speakers, rows: rows([.speakers]), action: .knownVoices))
        }

        result.append(Section(kind: .connections, rows: rows([.linkedFrom, .similar])))

        var sharing: [Row.Kind] = [.sharing]
        if context.activityLine != nil { sharing.append(.activity) }
        sharing.append(.origin)
        result.append(Section(kind: .sharingActivity, rows: rows(sharing)))
        return result
    }

    /// The type row's to-do switch can be used: the entry may be a to-do (`Note.canBeTodo`) or is one, and it can
    /// be changed here.
    static func canSwitchTodo(_ note: Note, context: EntryContext) -> Bool {
        !note.isDeleted && !context.isReadOnly && (note.isTodo || note.canBeTodo)
    }

    /// The type row shows the switch at all: the entry is a to-do or may become one (locked: shown, not usable).
    static func showsTodoSwitch(_ note: Note) -> Bool {
        note.isTodo || note.canBeTodo
    }

    // MARK: Words of the rows (the same on iPhone and Mac)

    /// The label in a row's label column.
    static func label(_ row: Row.Kind, for note: Note) -> String {
        switch row {
        case .type: String(localized: "Type")
        case .bowl: String(localized: "Bowl")
        case .suggestedBowl: String(localized: "Suggested")
        case .due: String(localized: "Due")
        case .repeat: String(localized: "Repeat")
        case .tags: String(localized: "Tags")
        case .appointment: String(localized: "Linked")
        case .sameAppointment: String(localized: "Same")
        case .documentKind: String(localized: "Kind")
        case .sender: String(localized: "Sender")
        case .dated: String(localized: "Dated")
        case .amount: String(localized: "Amount")
        case .speakers: String(localized: "Speakers")
        case .linkedFrom: String(localized: "Linked From")
        case .similar: String(localized: "Similar")
        case .sharing: String(localized: "Bowl")
        case .activity: String(localized: "Activity")
        case .origin: origin(for: note).label
        }
    }

    /// What the type row names: the kind without its to-do state (that is the switch beside it). "Note", "Meeting",
    /// "Link", "Image", "PDF", "File".
    static func typeName(for note: Note) -> String {
        switch EntryKind(note) {
        case .note, .todo: String(localized: "Note")
        case .meeting: String(localized: "Meeting")
        case .link: String(localized: "Link")
        case .image: String(localized: "Image")
        case .document: note.attachments.first?.kind == .pdf ? String(localized: "PDF") : String(localized: "File")
        }
    }

    /// The bowl's sharing, for Sharing & Activity: "Shared with Anna and Ben", "Shared by Anna, view only", or
    /// "Not shared" (also for the Inbox).
    static func sharingText(for note: Note) -> String {
        let sharing = BowlSharing.shared
        for key in note.projectIDs {
            if let info = sharing.info(for: UUID(uuidString: key)) { return info.summary }
        }
        return String(localized: "Not shared")
    }

    /// Where the entry came from, for Sharing & Activity: "Recorded · MacBook Pro Microphone · 24 Nov 10:00",
    /// "Came In · By Mail · 23 Nov 9:12", "Created · 24 Nov 9:00".
    static func origin(for note: Note, now: Date = Date()) -> (label: String, value: String) {
        let when = EntryMeta.dateText(note.createdAt, now: now)
        if note.isRecording {
            let how: String
            switch note.source {
            case .plaud: how = "Plaud"
            case .audioImport: how = String(localized: "Imported Audio")
            default: how = note.inputName ?? String(localized: "Microphone")
            }
            return (String(localized: "Recorded"), how + " · " + when)
        }
        if note.isLink {
            return (String(localized: "Saved"), [note.domain, when].compactMap { $0 }.joined(separator: " · "))
        }
        if note.source == .share || note.isStored {
            // A mail's entry starts with its header lines (`MailNote.text`).
            let mail = note.text.hasPrefix(MailNote.fromLabel)
            return (String(localized: "Came In"), (mail ? String(localized: "By Mail") : String(localized: "Shared")) + " · " + when)
        }
        return (String(localized: "Created"), when)
    }

    /// The bowl suggested for an entry in the Inbox: the first suggestion that is an active bowl I may file into.
    /// The same as the head's "✦ File into …" (`EntryMeta.suggestion`).
    static func suggestion(for note: Note, context: EntryContext) -> NoteFolder? {
        guard note.isInInbox, !context.isReadOnly else { return nil }
        for key in note.suggestedProjectIDs {
            guard let bowl = context.bowl(key), !bowl.isArchived, !BowlSharing.shared.isReadOnly(bowl.id) else { continue }
            return bowl
        }
        return nil
    }

    // MARK: Several entries

    /// What Details offers for several selected entries: only what they have in common.
    enum CommonField: Equatable {
        /// One bowl for all, or the Inbox (`Documents.BulkChange.move`).
        case bowl
        /// Later ▸, when all are in the Inbox.
        case later
        /// One due day, when all are to-dos.
        case due
        /// When all are stored files (`Documents.BulkChange.kind`).
        case documentKind
        /// "Set Sender of N…" (`Documents.BulkChange.sender`).
        case sender(count: Int)
        /// "Merge N PDFs…", for two PDFs or more.
        case mergePDFs(count: Int)
        /// "Delete N".
        case delete(count: Int)
    }

    /// The fields several entries share, in the order Details shows them. Entries in Recently Deleted or in a bowl
    /// I may only see change nowhere, so they leave no field (`Documents.apply` skips them too).
    static func commonFields(for notes: [Note], isReadOnly: ((Note) -> Bool)? = nil) -> [CommonField] {
        let isReadOnly = isReadOnly ?? { BowlSharing.shared.isReadOnly($0) }
        let notes = notes.filter { !$0.isDeleted && !isReadOnly($0) }
        guard !notes.isEmpty else { return [] }
        var fields: [CommonField] = [.bowl]
        if notes.allSatisfy(\.isInInbox) { fields.append(.later) }
        if notes.allSatisfy(\.isTodo) { fields.append(.due) }
        if notes.allSatisfy(\.isStored) {
            fields += [.documentKind, .sender(count: notes.count)]
        }
        let pdfs = DocumentFiles.mergeable(notes)
        if pdfs.count >= 2 { fields.append(.mergePDFs(count: pdfs.count)) }
        fields.append(.delete(count: notes.count))
        return fields
    }
}
