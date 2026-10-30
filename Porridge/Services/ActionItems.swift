import Foundation
import SwiftData

/// Takes the tasks and decisions out of a summary and keeps them as `ActionItem`s: the "Action Items"
/// and "Decisions" sections the model writes (in any language), plus checklist lines anywhere in the
/// summary. Ticking an item ticks its line in the summary too, so both always tell the same.
enum ActionItems {
    /// One line of a summary that is a task or a decision.
    struct Parsed: Equatable {
        var kind: ActionItem.Kind
        var text: String
        var owner: String?
        var done: Bool
        /// The line is a `- [ ]` checklist line (a plain bullet under the tasks heading is a task too).
        var isCheckbox: Bool
        /// Index of the line in the summary.
        var line: Int

        /// What an item is matched by between summary and store: kind and wording.
        var key: String { ActionItems.key(kind: kind, text: text, owner: owner) }
    }

    private enum Section {
        case none, tasks, decisions, other
    }

    private static let taskHeadings = [
        "action item", "tasks", "task", "to-do", "todo", "next step", "aufgaben", "offene punkte", "nächste schritte",
        "actions à mener", "actions", "tareas", "attività", "acties", "tarefas", "zadania",
    ]
    private static let decisionHeadings = [
        "decision", "entscheidung", "beschl", "décision", "decisione", "decisiones", "besluit", "decisõe", "decyzj",
    ]

    // MARK: - Reading a summary

    static func parse(_ summary: String) -> [Parsed] {
        var result: [Parsed] = []
        var section = Section.none
        for (index, raw) in summary.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                section = classify(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
                continue
            }
            guard let bullet = bullet(of: line) else { continue }
            var body = String(line.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
            var done = false
            var isCheckbox = false
            for (mark, value) in [("[ ]", false), ("[x]", true), ("[X]", true)] where body.hasPrefix(mark) {
                body = String(body.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
                done = value
                isCheckbox = true
            }
            body = body.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty, !saysNone(body) else { continue }
            if isCheckbox || section == .tasks {
                let (text, owner) = splitOwner(body)
                result.append(Parsed(kind: .task, text: text, owner: owner, done: done, isCheckbox: isCheckbox, line: index))
            } else if section == .decisions {
                result.append(Parsed(kind: .decision, text: body, owner: nil, done: false, isCheckbox: false, line: index))
            }
        }
        return result
    }

    /// "Keine Aufgaben genannt." / "No action items." is not a task.
    private static func saysNone(_ body: String) -> Bool {
        let text = body.lowercased()
        guard text.count <= 60 else { return false }
        return ["keine ", "no ", "none", "aucun", "ningun", "nessun", "geen ", "nenhum", "brak "].contains { text.hasPrefix($0) }
            && ["aufgabe", "task", "action", "entscheid", "decision", "none", "décision", "tarea", "decisi", "actie", "besluit", "tarefa", "zadani", "decyz", "offen", "open"].contains { text.contains($0) }
    }

    private static func classify(_ heading: String) -> Section {
        let name = heading.lowercased()
        if taskHeadings.contains(where: { name.contains($0) }) { return .tasks }
        if decisionHeadings.contains(where: { name.contains($0) }) { return .decisions }
        return .other
    }

    /// The list mark at the start of a line ("- ", "1. "), or nil for a paragraph.
    private static func bullet(of line: String) -> String? {
        for mark in ["- ", "* ", "• ", "+ "] where line.hasPrefix(mark) { return mark }
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3, line.dropFirst(digits.count).hasPrefix(". ") {
            return String(line.prefix(digits.count + 2))
        }
        return nil
    }

    /// "Task – Anna" → ("Task", "Anna"). Only a short tail after a dash counts as the owner.
    static func splitOwner(_ body: String) -> (String, String?) {
        for dash in [" – ", " — ", " - "] {
            guard let range = body.range(of: dash, options: .backwards) else { continue }
            let text = body[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let tail = body[range.upperBound...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".;"))
            if !text.isEmpty, !tail.isEmpty, tail.count <= 40, !tail.contains(". "), tail.split(separator: " ").count <= 4 {
                return (text, tail)
            }
        }
        return (body, nil)
    }

    /// What a summary line is matched by: the line it was made from, even after the task was renamed.
    static func matchKey(_ item: ActionItem) -> String {
        item.summaryKey ?? key(kind: item.kind, text: item.text, owner: item.owner)
    }

    /// Nothing was changed by hand: still the summary's wording, no text of its own, not ticked.
    static func isUntouched(_ item: ActionItem) -> Bool {
        item.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !item.isDone
            && key(kind: item.kind, text: item.text, owner: item.owner) == matchKey(item)
    }

    static func key(kind: ActionItem.Kind, text: String, owner: String?) -> String {
        let words = (text + " " + (owner ?? "")).lowercased()
            .components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty }
        return kind.rawValue + ":" + words.joined(separator: " ")
    }

    // MARK: - Keeping the store in step

    static func items(of noteID: UUID, in context: ModelContext) -> [ActionItem] {
        let descriptor = FetchDescriptor<ActionItem>(predicate: #Predicate { $0.noteID == noteID }, sortBy: [SortDescriptor(\.order)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Brings the note's items in step with its summary: new lines become items, ticked lines tick their
    /// item. A line that is gone takes its item with it only while nobody touched it; an edited, ticked or
    /// written-into task stays as a task of its own. Cheap when nothing changed.
    static func sync(_ note: Note, in context: ModelContext) {
        // A saved page never gives tasks: whatever its summary lists is reading matter, not work.
        let parsed = note.isLink ? [] : parse(note.summary ?? "")
        var remaining: [String: [ActionItem]] = [:]
        for item in items(of: note.id, in: context) where item.isFromSummary {
            remaining[matchKey(item), default: []].append(item)
        }
        // Two devices may both have made the items before iCloud brought the other's: every device keeps the
        // same one (the smallest id), so the copies go and nothing is lost on both sides.
        for key in remaining.keys { remaining[key]?.sort { $0.id.uuidString < $1.id.uuidString } }
        var changed = false
        for (order, line) in parsed.enumerated() {
            let item: ActionItem
            if var list = remaining[line.key], !list.isEmpty {
                item = list.removeFirst()
                remaining[line.key] = list
                // A copy ticked on the other device counts.
                if let copy = list.first(where: \.isDone), !item.isDone, !line.isCheckbox {
                    item.isDone = true
                    item.doneAt = copy.doneAt
                    changed = true
                }
            } else {
                item = ActionItem()
                item.noteID = note.id
                item.kind = line.kind
                item.text = line.text
                item.owner = line.owner
                item.summaryKey = line.key
                item.createdAt = note.summarizedAt ?? Date()
                context.insert(item)
                changed = true
            }
            if item.order != order { item.order = order; changed = true }
            if line.isCheckbox, item.isDone != line.done {
                item.isDone = line.done
                item.doneAt = line.done ? Date() : nil
                changed = true
            }
        }
        for item in remaining.values.flatMap({ $0 }) {
            if isUntouched(item) || note.isLink {
                context.delete(item)
            } else {
                item.source = "kept"
            }
            changed = true
        }
        if changed { try? context.save() }
    }

    /// Brings every note's items in step with its summary at launch: notes summarized before there were
    /// items get theirs, copies from another device go, pages lose theirs. Cheap: nothing is written
    /// when nothing changed.
    static func backfill(_ notes: [Note], in context: ModelContext) {
        for note in notes where !note.isDeleted {
            if note.isLink || !(note.summary ?? "").isEmpty { sync(note, in: context) }
        }
    }

    /// Makes a task typed by hand and returns it, ready to be filled in.
    static func newTask(in context: ModelContext) -> ActionItem {
        let item = ActionItem()
        item.source = "manual"
        context.insert(item)
        return item
    }

    static func delete(_ item: ActionItem, in context: ModelContext) {
        context.delete(item)
        try? context.save()
    }

    /// The note (or its summary) goes: untouched tasks go with it, the others stay as tasks of their own.
    static func remove(of noteID: UUID, in context: ModelContext) {
        for item in items(of: noteID, in: context) {
            if isUntouched(item) {
                context.delete(item)
            } else {
                item.noteID = nil
                item.source = "kept"
            }
        }
    }

    /// Ticks or unticks an item and its line in the summary.
    static func setDone(_ item: ActionItem, _ done: Bool, note: Note?, in context: ModelContext) {
        item.isDone = done
        item.doneAt = done ? Date() : nil
        item.updatedAt = Date()
        if let note, item.isFromSummary, var summary = note.summary {
            let target = matchKey(item)
            var lines = summary.components(separatedBy: "\n")
            // The n-th item with the same wording ticks the n-th line with it.
            let siblings = items(of: note.id, in: context).filter { $0.isFromSummary && matchKey($0) == target }
            let position = siblings.firstIndex { $0.id == item.id } ?? 0
            let matches = parse(summary).filter { $0.key == target }
            if position < matches.count {
                let line = matches[position]
                lines[line.line] = ticked(lines[line.line], done: done, isCheckbox: line.isCheckbox)
                summary = lines.joined(separator: "\n")
                if summary != note.summary { note.summary = summary }
            }
        }
        try? context.save()
    }

    private static func ticked(_ line: String, done: Bool, isCheckbox: Bool) -> String {
        if isCheckbox {
            for mark in ["[ ]", "[x]", "[X]"] {
                if let range = line.range(of: mark) {
                    return line.replacingCharacters(in: range, with: done ? "[x]" : "[ ]")
                }
            }
            return line
        }
        // A plain bullet under the tasks heading becomes a checklist line once it is ticked.
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
        let rest = line.dropFirst(indent.count)
        guard let mark = bullet(of: String(rest)) else { return line }
        return indent + "- " + (done ? "[x] " : "[ ] ") + rest.dropFirst(mark.count)
    }

    // MARK: - For the chat

    /// The open tasks and the decisions as a block of text for the model, newest note first, at most `limit` characters.
    static func contextBlock(items: [ActionItem], notes: [Note], limit: Int) -> String {
        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func line(_ item: ActionItem) -> String? {
            let details = item.details.trimmingCharacters(in: .whitespacesAndNewlines)
            let more = details.isEmpty ? "" : "\n  " + String(details.prefix(240)).replacingOccurrences(of: "\n", with: " ")
            guard let id = item.noteID, let note = byID[id] else {
                return "- \(item.line) (task of its own, \(item.createdAt.formatted(date: .abbreviated, time: .omitted)))" + more
            }
            guard !note.isDeleted else { return nil }
            return "- \(item.line) («\(note.displayTitle)», \(note.createdAt.formatted(date: .abbreviated, time: .omitted)))" + more
        }
        let dated = items.compactMap { item -> (Date, ActionItem)? in
            guard let id = item.noteID, let note = byID[id] else { return (item.createdAt, item) }
            guard !note.isDeleted, !note.isLink else { return nil }
            return (note.createdAt, item)
        }.sorted { $0.0 > $1.0 }.map(\.1)
        let open = dated.filter { $0.kind == .task && !$0.isDone }.compactMap(line)
        let done = dated.filter { $0.kind == .task && $0.isDone }.prefix(10).compactMap(line)
        let decisions = dated.filter { $0.kind == .decision }.compactMap(line)
        var text = ""
        func add(_ title: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            var block = title + "\n"
            for entry in lines where text.count + block.count + entry.count < limit { block += entry + "\n" }
            text += block + "\n"
        }
        add("Open tasks (from the summaries, with the note they come from):", open)
        add("Done tasks (recent):", done)
        add("Decisions (from the summaries):", decisions)
        return text
    }
}
