import Foundation
import SwiftData

/// The task lines of a summary: the "Action Items" section the model writes (in any language) and checklist
/// lines anywhere in it. They live in the summary's text only; ticking one changes that line.
enum SummaryTasks {
    /// One line of a summary that is a task.
    struct Parsed: Equatable {
        var text: String
        var done: Bool
        /// The line is a `- [ ]` checklist line (a plain bullet under the tasks heading is a task too).
        var isCheckbox: Bool
        /// Index of the line in the summary.
        var line: Int
    }

    private enum Section {
        case none, tasks, other
    }

    private static let taskHeadings = [
        "action item", "tasks", "task", "to-do", "todo", "next step", "aufgaben", "offene punkte", "nächste schritte",
        "actions à mener", "actions", "tareas", "attività", "acties", "tarefas", "zadania",
    ]

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
                result.append(Parsed(text: body, done: done, isCheckbox: isCheckbox, line: index))
            }
        }
        return result
    }

    /// A checkbox in the summary was tapped. A saved page has no tasks to tick.
    static func toggleLine(_ line: Int, of note: Note, in context: ModelContext) {
        guard !note.isLink, let summary = note.summary,
              let task = parse(summary).first(where: { $0.line == line }) else { return }
        var lines = summary.components(separatedBy: "\n")
        lines[line] = ticked(lines[line], done: !task.done, isCheckbox: task.isCheckbox)
        note.summary = lines.joined(separator: "\n")
        note.updatedAt = Date()
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

    /// "Keine Aufgaben genannt." / "No action items." is not a task.
    private static func saysNone(_ body: String) -> Bool {
        let text = body.lowercased()
        guard text.count <= 60 else { return false }
        return ["keine ", "no ", "none", "aucun", "ningun", "nessun", "geen ", "nenhum", "brak "].contains { text.hasPrefix($0) }
            && ["aufgabe", "task", "action", "none", "tarea", "actie", "tarefa", "zadani", "offen", "open"].contains { text.contains($0) }
    }

    private static func classify(_ heading: String) -> Section {
        let name = heading.lowercased()
        return taskHeadings.contains(where: { name.contains($0) }) ? .tasks : .other
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
}
