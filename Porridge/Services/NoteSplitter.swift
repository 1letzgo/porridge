import Foundation
import SwiftData

/// What "Split into Bowl…" proposes for a long note: a new bowl and the entries cut out of the note (its topics as
/// notes, its tasks as to-dos). Only a proposal: the review sheet shows it, the user changes or drops parts of it,
/// and nothing is made before "Create".
struct SplitProposal: Equatable {
    struct Entry: Equatable, Identifiable {
        var id = UUID()
        var title: String
        var text: String
        var isTodo: Bool
        /// "yyyy-MM-dd" for a to-do whose words name a day.
        var dueDay: String?
        /// Chosen in the review sheet.
        var isIncluded = true
    }

    var bowlName: String
    var entries: [Entry]
    /// Written by a language model (`SummaryModel.label`); nil for the split by the note's own structure.
    var modelLabel: String?

    var included: [Entry] { entries.filter(\.isIncluded) }
}

/// Splits a long note (or a meeting's summary) into a bowl with several entries. The note's own structure gives a
/// proposal at once (headings, paragraphs, task lines); a language model, when one can run without a download,
/// gives a better one. The note itself is never changed, archived or deleted; it can go into the new bowl too.
enum NoteSplitter {
    /// Shorter notes have nothing to split.
    static let minimumLength = 280

    /// The text that is split: the note's own text, and for a meeting its summary as well.
    static func material(of note: Note) -> String {
        let own = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.isRecording, let summary = note.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else { return own }
        return own.isEmpty ? summary : summary + "\n\n" + own
    }

    /// Whether "Split into Bowl…" is offered: the user's own words (no saved link or file), long enough or with
    /// several headings.
    static func canSplit(_ note: Note) -> Bool {
        guard !note.isSaved, !note.isStored, !note.isDeleted else { return false }
        let text = material(of: note)
        return text.count >= minimumLength || headingCount(text) >= 2
    }

    private static func headingCount(_ text: String) -> Int {
        text.components(separatedBy: "\n").filter { heading(of: $0) != nil }.count
    }

    /// "## Budget" → "Budget"; also a short line in bold ("**Budget**") or ending in a colon ("Budget:").
    static func heading(of raw: String) -> String? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") {
            let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title.replacingOccurrences(of: "**", with: "")
        }
        if line.count >= 5, line.count <= 60, line.hasPrefix("**"), line.hasSuffix("**") {
            let title = line.dropFirst(2).dropLast(2).trimmingCharacters(in: .whitespaces)
            return title.isEmpty ? nil : title
        }
        if line.count >= 3, line.count <= 50, line.hasSuffix(":"), !line.hasPrefix("-"), !line.hasPrefix("*"),
           line.split(separator: " ").count <= 6 {
            return String(line.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: By the note's own structure

    /// A proposal from the note's structure alone: each heading's section (or, without headings, each paragraph)
    /// is a note; checklist lines and lines that read like tasks (`TaskDetection`) are to-dos of their own.
    static func structural(title: String, text: String, now: Date = Date(), calendar: Calendar = .current) -> SplitProposal {
        var sections: [(title: String?, lines: [String])] = []
        var tasks: [SplitProposal.Entry] = []
        var seenTasks = Set<String>()
        let hasHeadings = headingCount(text) > 0
        var current: (title: String?, lines: [String]) = (nil, [])
        var inFence = false

        func closeSection() {
            if current.lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) || current.title != nil {
                sections.append(current)
            }
            current = (nil, [])
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle() }
            if !inFence, let heading = heading(of: raw) {
                closeSection()
                current.title = heading
                continue
            }
            if !inFence, let task = task(in: line) {
                let key = TodoSuggestions.key(task)
                if !key.isEmpty, seenTasks.insert(key).inserted {
                    let due = TodoSuggestions.dueDay(from: task, meetingDate: now, calendar: calendar, strict: true)
                    tasks.append(SplitProposal.Entry(title: task, text: "", isTodo: true, dueDay: due))
                }
                continue
            }
            // Without headings a blank line ends a topic.
            if !hasHeadings, !inFence, line.isEmpty {
                closeSection()
                continue
            }
            current.lines.append(raw)
        }
        closeSection()

        var notes: [SplitProposal.Entry] = []
        for section in sections {
            let body = section.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty, section.title == nil { continue }
            // A heading over nothing but tasks: the tasks are the entries.
            if body.isEmpty { continue }
            let title = section.title ?? firstWords(of: body)
            notes.append(SplitProposal.Entry(title: title, text: body, isTodo: false))
        }
        return SplitProposal(bowlName: bowlName(title: title, text: text), entries: notes + tasks, modelLabel: nil)
    }

    /// An open checklist line, or a line that reads like a task. Ticked lines are done and stay in their section.
    private static func task(in line: String) -> String? {
        let open = ["- [ ] ", "* [ ] ", "+ [ ] "]
        if let mark = open.first(where: { line.hasPrefix($0) }) {
            let body = String(line.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : body
        }
        return TaskDetection.taskText(of: line)
    }

    /// The first line of a text, without marks, cut at about 60 characters.
    static func firstWords(of text: String) -> String {
        let first = NoteText.plainLines(text).first ?? text
        guard first.count > 60 else { return first }
        let cut = first.prefix(60)
        if let space = cut.lastIndex(of: " ") { return String(cut[..<space]) + "…" }
        return String(cut) + "…"
    }

    /// The note's title; else its first heading; else its first words.
    static func bowlName(title: String, text: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return String(title.prefix(60)) }
        if let heading = text.components(separatedBy: "\n").lazy.compactMap({ heading(of: $0) }).first { return heading }
        return firstWords(of: text)
    }

    // MARK: With a language model

    static func prompt(_ language: SummaryLanguage) -> String {
        """
        You split a long personal note into a project folder with several separate entries. The note is written in \(language.name). Write everything in \(language.name) only, even though these instructions are in English.
        - First line: BOWL: <a short name for the folder, 1 to 4 words>
        - Then one block per topic: a line "## <short title>" followed by that topic's content from the note, rewritten as little as possible. Keep every fact, name, number and date.
        - Then every concrete task as its own line: TODO: <task>
        - Two to eight topics. Do not invent anything. No introduction, no comment, no code block.
        """
    }

    /// Reads an answer in the format of `prompt`. Nil when it holds no entry.
    static func parse(_ answer: String, fallbackName: String, now: Date = Date(), calendar: Calendar = .current) -> SplitProposal? {
        var name: String?
        var entries: [SplitProposal.Entry] = []
        var title: String?
        var lines: [String] = []
        var seenTasks = Set<String>()

        func close() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if let title, !body.isEmpty || !title.isEmpty {
                entries.append(SplitProposal.Entry(title: title, text: body, isTodo: false))
            }
            title = nil
            lines = []
        }

        for raw in answer.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { continue }
            let upper = line.uppercased()
            if name == nil, upper.hasPrefix("BOWL:") {
                name = line.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'*<>`"))
                continue
            }
            if upper.hasPrefix("TODO:") || line.hasPrefix("- [ ] ") {
                let task = (upper.hasPrefix("TODO:") ? String(line.dropFirst(5)) : String(line.dropFirst(6)))
                    .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
                let key = TodoSuggestions.key(task)
                if !key.isEmpty, seenTasks.insert(key).inserted {
                    entries.append(SplitProposal.Entry(title: task, text: "", isTodo: true,
                                                       dueDay: TodoSuggestions.dueDay(from: task, meetingDate: now, calendar: calendar, strict: true)))
                }
                continue
            }
            if line.hasPrefix("#") {
                close()
                title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
                continue
            }
            if title == nil, !line.isEmpty { title = firstWords(of: line) }
            lines.append(raw)
        }
        close()
        // Topics first, to-dos after them, as the sheet lists them.
        entries = entries.filter { !$0.isTodo } + entries.filter(\.isTodo)
        guard !entries.isEmpty else { return nil }
        let bowl = (name?.isEmpty == false ? name! : fallbackName)
        return SplitProposal(bowlName: String(bowl.prefix(60)), entries: entries, modelLabel: nil)
    }

    /// Longest material the model is given in one go (the Apple model has a small window).
    static func modelLimit(_ model: SummaryModel) -> Int {
        if case .local(let local) = model { return local == .apple ? 4_500 : 12_000 }
        return 40_000
    }
}

@MainActor
extension NoteSplitter {
    /// The model a split may use now: the default one, when it can answer without a download first.
    static var availableModel: SummaryModel? {
        let model = SummaryModel.current
        return model.isUsable && model.isOnHand ? model : nil
    }

    /// The proposal of the model for the note. Throws when the model fails; the caller keeps the structural one.
    static func proposeWithModel(_ note: Note, model: SummaryModel) async throws -> SplitProposal {
        let text = material(of: note)
        guard !text.isEmpty else { throw SummaryError.emptyNote }
        guard text.count <= modelLimit(model) else { throw SummaryError.tooLongToEnhance }
        let language = SummaryLanguage.detect(in: text)
        let system = prompt(language)
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = (title.isEmpty ? "" : "Title: \(title)\n\n") + "Note:\n\(text)\n\nWrite in \(language.name)."
        let answer: String
        switch model {
        case .local(let local):
            let models = ModelManager.shared
            models.beginLLMUse()
            defer { models.endLLMUse() }
            try await models.ensureLLM(local) { _ in }
            answer = try await LocalLLM.shared.generate(model: local, system: system, user: user, maxTokens: min(4_000, text.count / 2 + 800))
        case .cloud(let provider, let id):
            let key = provider.apiKey
            if provider.requiresKey, key.isEmpty { throw SummaryError.missingAPIKey(provider.label) }
            answer = try await CloudLLM.complete(provider: provider, apiKey: key, model: id, system: system, user: user)
        }
        guard var proposal = parse(answer, fallbackName: bowlName(title: note.title, text: text)) else { throw SummaryError.emptyResponse }
        proposal.modelLabel = model.label
        return proposal
    }

    /// Makes what the proposal holds: the bowl (or the active one of that name), each chosen entry in it, and, when
    /// `moveSource`, the note itself into it too. To-dos point back to the note (`todoSourceID`).
    static func apply(_ proposal: SplitProposal, from note: Note, moveSource: Bool, in context: ModelContext) -> BowlChange? {
        guard let found = BowlMaking.findOrCreate(proposal.bowlName, in: context) else { return nil }
        let bowl = found.bowl, created = found.created
        let key = Projects.key(bowl)
        var made: [UUID] = []
        let now = Date()
        for (offset, entry) in proposal.included.enumerated() {
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || !text.isEmpty else { continue }
            let new = Note()
            new.title = title
            new.titleIsCustom = !title.isEmpty
            new.text = text
            new.source = .note
            // In the order of the sheet, the first one newest on top of lists sorted by date.
            new.createdAt = now.addingTimeInterval(-Double(offset))
            new.updatedAt = new.createdAt
            new.projectIDs = [key]
            new.filedAt = now
            if entry.isTodo {
                new.todoState = .open
                new.todoSourceID = note.id.uuidString
                if let due = entry.dueDay, Todos.isDueKey(due) { new.todoDueDay = due }
            }
            context.insert(new)
            made.append(new.id)
        }
        var moved: [BowlChange.Moved] = []
        if moveSource, note.modelContext != nil { moved.append(BowlMaking.move(note, into: bowl, in: context)) }
        try? context.save()
        return BowlChange(bowlID: bowl.id, bowlName: bowl.name, createdBowl: created, createdNoteIDs: made, moved: moved)
    }
}
