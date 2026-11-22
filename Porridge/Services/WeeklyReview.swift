import Foundation

/// The weekly review: what came in during a week (counts by kind, the meetings, the documents), the open to-dos with
/// their due days, and the bowls that grew. A summary to look back on, not a planner: nothing is moved or scheduled.
/// Optionally the summary model writes a few sentences about the week.
struct WeeklyReview {
    /// The kinds counted, in the order shown.
    enum Kind: String, CaseIterable, Identifiable {
        case meetings, notes, todos, links, documents, images, files

        var id: String { rawValue }

        var title: String {
            switch self {
            case .meetings: String(localized: "Meetings")
            case .notes: String(localized: "Notes")
            case .todos: String(localized: "To-dos")
            case .links: String(localized: "Links")
            case .documents: String(localized: "Documents")
            case .images: String(localized: "Images")
            case .files: String(localized: "Files")
            }
        }

        var systemImage: String {
            switch self {
            case .meetings: "waveform"
            case .notes: "text.alignleft"
            case .todos: "checklist"
            case .links: "link"
            case .documents: "doc.richtext"
            case .images: "photo"
            case .files: "doc"
            }
        }

        /// One kind per entry: a document is counted as a document, not also as a file.
        static func of(_ note: Note) -> Kind {
            if note.isTodo { return .todos }
            if note.isLink { return .links }
            if note.isRecording { return .meetings }
            if note.isStored {
                if note.isDocument { return .documents }
                return note.isImage ? .images : .files
            }
            return .notes
        }
    }

    struct Meeting: Identifiable {
        var id: UUID
        var title: String
        var date: Date
        var duration: Double
        /// Tasks of its summary still waiting to become to-dos.
        var pendingTodos: Int
    }

    struct Document: Identifiable {
        var id: UUID
        var title: String
        var kind: String?
        var sender: String?
    }

    struct OpenTodo: Identifiable {
        var id: UUID
        var title: String
        /// "yyyy-MM-dd", or nil.
        var dueDay: String?
        var isOverdue: Bool
        var bowl: String?
    }

    struct BowlGrowth: Identifiable {
        var id: String
        var name: String
        var added: Int
    }

    /// The week shown: Monday (or the calendar's first weekday) to the next.
    var week: DateInterval
    var total: Int
    var counts: [(kind: Kind, count: Int)]
    var meetings: [Meeting]
    var documents: [Document]
    var openTodos: [OpenTodo]
    var bowls: [BowlGrowth]
    var doneTodos: Int

    var isEmpty: Bool { total == 0 && openTodos.isEmpty && doneTodos == 0 }

    /// The week containing `now`, `offset` weeks back (-1 is last week).
    static func week(containing now: Date, offset: Int = 0, calendar: Calendar = .current) -> DateInterval {
        let base = calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: calendar.startOfDay(for: now), duration: 7 * 86_400)
        guard offset != 0, let start = calendar.date(byAdding: .weekOfYear, value: offset, to: base.start) else { return base }
        return calendar.dateInterval(of: .weekOfYear, for: start) ?? base
    }

    /// Works the review out of the entries and bowls. Pure: tested without a store.
    static func make(notes: [Note], bowls: [NoteFolder], week: DateInterval, now: Date = Date(), calendar: Calendar = .current) -> WeeklyReview {
        let living = notes.filter { !$0.isDeleted }
        let inWeek = { (date: Date) in date >= week.start && date < week.end }
        let new = living.filter { inWeek($0.createdAt) }

        var byKind: [Kind: Int] = [:]
        for note in new { byKind[Kind.of(note), default: 0] += 1 }
        let counts = Kind.allCases.compactMap { kind in byKind[kind].map { (kind: kind, count: $0) } }

        let made = Dictionary(grouping: living.filter { $0.todoSourceID != nil }, by: { $0.todoSourceID ?? "" })
        let meetings = new.filter { Kind.of($0) == .meetings }
            .sorted { $0.createdAt < $1.createdAt }
            .map { note in
                Meeting(id: note.id, title: note.displayTitle, date: note.createdAt, duration: note.duration,
                        pendingTodos: note.pendingTodoSuggestions(made: made[note.id.uuidString] ?? []).count)
            }

        let documents = new.filter { Kind.of($0) == .documents }
            .sorted { $0.createdAt < $1.createdAt }
            .map { Document(id: $0.id, title: $0.displayTitle, kind: $0.documentInfo?.kind?.title, sender: $0.documentInfo?.correspondent) }

        let names = Dictionary(bowls.map { (Projects.key($0), $0.name) }, uniquingKeysWith: { a, _ in a })
        // Open to-dos due by the end of the week (late ones included), by due day; then new ones without a day.
        let open = living.filter { $0.isTodo && !$0.isDone }
        let due = open.filter { note in
            guard let key = note.todoDue, let date = Todos.dueDate(key, calendar: calendar) else { return false }
            return date < week.end
        }
        let undated = open.filter { $0.todoDue == nil && inWeek($0.createdAt) }
        let openTodos = (Todos.byDue(due) + undated.sorted { $0.createdAt < $1.createdAt }).map { note in
            OpenTodo(
                id: note.id, title: note.displayTitle, dueDay: note.todoDue,
                isOverdue: note.todoDue.flatMap { Todos.dueStatus($0, now: now, calendar: calendar) } == .overdue,
                bowl: note.projectIDs.first.flatMap { names[$0] }
            )
        }
        let doneTodos = living.filter { $0.isDone && ($0.todoDoneAt.map(inWeek) ?? false) }.count

        // A bowl grew by what was filed into it this week (or made in it).
        var added: [String: Int] = [:]
        for note in living {
            guard let bowl = note.projectIDs.first, names[bowl] != nil else { continue }
            let came = note.filedAt.map(inWeek) ?? inWeek(note.createdAt)
            if came { added[bowl, default: 0] += 1 }
        }
        let growth = added
            .map { BowlGrowth(id: $0.key, name: names[$0.key] ?? "", added: $0.value) }
            .sorted { $0.added != $1.added ? $0.added > $1.added : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return WeeklyReview(
            week: week, total: new.count, counts: counts, meetings: meetings, documents: documents,
            openTodos: openTodos, bowls: growth, doneTodos: doneTodos
        )
    }

    /// "17–23 Nov", as the review's title.
    var title: String {
        let end = week.end.addingTimeInterval(-1)
        return week.start.formatted(.dateTime.day().month(.abbreviated)) + " – " + end.formatted(.dateTime.day().month(.abbreviated))
    }

    // MARK: The model's summary

    /// What the summary model reads: the counts and the titles (with the first line of each summary). No full texts.
    func prompt(notes: [Note]) -> String {
        var lines: [String] = ["Week: \(title)", "New entries: \(total)"]
        lines += counts.map { "\($0.kind.title): \($0.count)" }
        if !meetings.isEmpty {
            lines.append("\nMeetings:")
            let summaries = Dictionary(notes.map { ($0.id, $0.summary) }, uniquingKeysWith: { a, _ in a })
            for meeting in meetings.prefix(15) {
                let gist = summaries[meeting.id]??.split(separator: "\n").first { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                lines.append("- \(meeting.title)" + (gist.map { ": \($0.prefix(200))" } ?? ""))
            }
        }
        if !documents.isEmpty {
            lines.append("\nDocuments:")
            lines += documents.prefix(15).map { "- \($0.title)" + ($0.sender.map { " (from \($0))" } ?? "") }
        }
        if !openTodos.isEmpty {
            lines.append("\nOpen to-dos:")
            lines += openTodos.prefix(20).map { "- \($0.title)" + ($0.dueDay.map { " (due \($0))" } ?? "") + ($0.isOverdue ? " [overdue]" : "") }
        }
        if doneTodos > 0 { lines.append("\nTo-dos done this week: \(doneTodos)") }
        if !bowls.isEmpty {
            lines.append("\nBowls that grew:")
            lines += bowls.prefix(10).map { "- \($0.name): +\($0.added)" }
        }
        return lines.joined(separator: "\n")
    }

    static let systemPrompt = """
    You write a short look back on someone's week from a list of what came into their notes app. Write 3 to 5 plain \
    sentences: what the week was about, the meetings that stood out, what is still open. No headings, no lists, no \
    advice and no planning. Write in the language most of the titles are in.
    """
}

@MainActor
extension WeeklyReview {
    /// A few sentences about the week, by the summary model (on the device or the user's own key).
    func summarize(notes: [Note]) async throws -> String {
        let user = prompt(notes: notes)
        let model = SummaryModel.current
        switch model {
        case .local(let local):
            let models = ModelManager.shared
            models.beginLLMUse()
            defer { models.endLLMUse() }
            try await models.ensureLLM(local) { _ in }
            return try await LocalLLM.shared.generate(model: local, system: Self.systemPrompt, user: user, maxTokens: 400)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .cloud(let provider, let id):
            let key = provider.apiKey
            if provider.requiresKey, key.isEmpty { throw SummaryError.missingAPIKey(provider.label) }
            return try await CloudLLM.complete(provider: provider, apiKey: key, model: id, system: Self.systemPrompt, user: user)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
