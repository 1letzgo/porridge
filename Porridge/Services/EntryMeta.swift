import Foundation

/// The one meta line under an entry's title (iPhone and Mac): first the fixed facts in grey (kind · date ·
/// duration or pages · source), then only the values that are set, each a coloured word with a small symbol that
/// opens Details at its section. Never an empty value or a "+ …" placeholder. The views decide how many values fit
/// in two lines and show "+N" for the rest.
@MainActor
enum EntryMeta {
    /// One set value of the line.
    struct Value: Identifiable, Equatable {
        enum Kind: String, Equatable {
            case bowl, due, `repeat`, appointment, document, payment, speakers, tag, activity
        }

        /// The colour of the word; the views map it to their brand colours.
        enum Tone: Equatable {
            /// Violet (`BrandProjectText`): bowls, who changed what.
            case bowl
            /// Green (`BrandTaskText`): due, repeat, paid.
            case task
            /// Red (`BrandDangerText`): overdue.
            case danger
            /// Navy (`BrandNavy`): appointment, document, speakers.
            case navy
            /// Grey: tags, a document not paid yet.
            case secondary
        }

        let kind: Kind
        let text: String
        /// An SF Symbol; for a bowl the asset image "Bowl" (`bowlImage`).
        let symbol: String
        let tone: Tone
        /// The Details section a tap opens.
        let section: EntryDetails.Section.Kind
        /// A to-do's due day or a document's payment is past.
        var isOverdue = false

        var id: String { kind.rawValue + ":" + text }
    }

    /// The image the bowl value shows (in the asset catalogue both apps share), not an SF Symbol.
    static let bowlImage = "Bowl"

    /// The facts and the set values of an entry, in the line's order: bowl, due, repeat, appointment, document,
    /// payment, speakers, tags, activity.
    static func items(for note: Note, context: EntryContext) -> (facts: String, values: [Value]) {
        (facts(for: note, context: context), values(for: note, context: context))
    }

    // MARK: Facts

    /// "Meeting · Today 10:00 · 42 min", "PDF · 23 Nov · 3 pages", "To-do · 24 Nov · 2 of 4 subtasks".
    static func facts(for note: Note, context: EntryContext) -> String {
        var parts = [kindWord(for: note), dateText(note.createdAt, now: context.now)]
        if note.isRecording, note.duration > 0 { parts.append(note.duration.durationText) }
        if let pages = context.pageCount, pages > 0 {
            parts.append(pages == 1 ? String(localized: "1 page") : String(localized: "\(pages) pages"))
        }
        let progress = note.todoProgress
        if progress.total > 0 { parts.append(String(localized: "\(progress.done) of \(progress.total) subtasks")) }
        if let source = sourceWord(for: note) { parts.append(source) }
        return parts.joined(separator: " · ")
    }

    /// The kind as the line names it: a PDF is a "PDF", other files "File".
    static func kindWord(for note: Note) -> String {
        switch EntryKind(note) {
        case .note: String(localized: "Note")
        case .todo: String(localized: "To-do")
        case .meeting: note.isTodo ? String(localized: "To-do") : String(localized: "Meeting")
        case .link: String(localized: "Link")
        case .image: String(localized: "Image")
        case .document: note.attachments.first?.kind == .pdf ? String(localized: "PDF") : String(localized: "File")
        }
    }

    /// "Today 10:00", "Yesterday 18:30", "23 Nov", "23 Nov 2025".
    static func dateText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today \(time)") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday \(time)")
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// Where it came in, when that says something: the site of a link, Plaud, an imported recording.
    static func sourceWord(for note: Note) -> String? {
        if note.isLink { return note.domain }
        switch note.source {
        case .plaud: return "Plaud"
        case .audioImport: return String(localized: "Imported")
        default: return nil
        }
    }

    // MARK: Values

    static func values(for note: Note, context: EntryContext) -> [Value] {
        var values: [Value] = []
        // Bowl (one at most); the Inbox is no value.
        for key in note.projectIDs {
            guard let bowl = context.bowl(key) else { continue }
            values.append(Value(kind: .bowl, text: bowl.name, symbol: bowlImage, tone: .bowl, section: .organize))
            break
        }
        if let due = note.todoDue {
            let overdue = !note.isDone && Todos.dueStatus(due, now: context.now) == .overdue
            values.append(Value(
                kind: .due, text: String(localized: "Due \(Todos.dueLabel(due, now: context.now))"), symbol: "calendar",
                tone: overdue ? .danger : .task, section: .organize, isOverdue: overdue
            ))
        }
        if note.isTodo, let rule = note.todoRepeat {
            values.append(Value(kind: .repeat, text: rule.title, symbol: "repeat", tone: .task, section: .organize))
        }
        if let appointment = context.appointment {
            let text = appointment.isAllDay ? appointment.title
                : appointment.title + " " + appointment.start.formatted(date: .omitted, time: .shortened)
            values.append(Value(kind: .appointment, text: text, symbol: "calendar.badge.clock", tone: .navy, section: .appointment))
        }
        if note.isStored, let info = note.documentInfo {
            var parts: [String] = []
            if let kind = info.kind, kind != .other || info.correspondent == nil { parts.append(kind.title) }
            if let sender = info.correspondent { parts.append(sender) }
            if let amount = info.amountText, info.kind?.hasAmount ?? true { parts.append(amount) }
            if !parts.isEmpty {
                values.append(Value(
                    kind: .document, text: parts.joined(separator: " · "), symbol: info.kind?.symbol ?? "doc", tone: .navy, section: .document
                ))
            }
        }
        if let status = note.paymentStatus(now: context.now) {
            let value: Value
            switch status {
            case .open:
                value = Value(kind: .payment, text: String(localized: "Unpaid"), symbol: "creditcard", tone: .secondary, section: .document)
            case .overdue:
                value = Value(kind: .payment, text: String(localized: "Overdue"), symbol: "exclamationmark.circle", tone: .danger, section: .document, isOverdue: true)
            case .paid:
                value = Value(kind: .payment, text: String(localized: "Paid"), symbol: "checkmark.circle", tone: .task, section: .document)
            }
            values.append(value)
        }
        if note.isRecording, !note.speakers.isEmpty {
            values.append(Value(kind: .speakers, text: speakersText(note.speakers), symbol: "person.2", tone: .navy, section: .speakers))
        }
        for tag in note.tags {
            values.append(Value(kind: .tag, text: "#" + tag, symbol: "number", tone: .secondary, section: .organize))
        }
        if let activity = context.activityLine, !note.isDeleted {
            values.append(Value(kind: .activity, text: activity, symbol: "person.crop.circle.badge.clock", tone: .bowl, section: .sharingActivity))
        }
        return values
    }

    /// "4 Speakers · 1 unnamed", "1 Speaker".
    static func speakersText(_ speakers: [Speaker]) -> String {
        let count = speakers.count == 1 ? String(localized: "1 Speaker") : String(localized: "\(speakers.count) Speakers")
        let unnamed = speakers.filter { VoiceProfiles.isUnnamed($0) }.count
        return unnamed == 0 ? count : count + " · " + String(localized: "\(unnamed) unnamed")
    }

    // MARK: Suggestion

    /// The bowl of the "✦ File into …" pill: the first suggestion of an entry in the Inbox. An action, not a value;
    /// gone once the entry is filed.
    static func suggestion(for note: Note, context: EntryContext) -> NoteFolder? {
        EntryDetails.suggestion(for: note, context: context)
    }
}
