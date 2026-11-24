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
        guard !note.isSaved, let summary = note.summary,
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

    /// The summary with the given lines left empty, for the page: the line numbers stay, so ticking a box still finds
    /// its line in the stored summary. A tasks heading ("## Action Items", "### Aufgaben", "**Next Steps:**") goes too
    /// when nothing of its section is left but a "No further tasks." line. The stored summary is never changed by this.
    static func hiding(_ hidden: Set<Int>, in summary: String) -> String {
        guard !hidden.isEmpty else { return summary }
        var lines = summary.components(separatedBy: "\n")
        var label: Int?
        var noneLines: [Int] = []
        var hiddenUnder = false
        var visibleUnder = false
        func close() {
            if let label, hiddenUnder, !visibleUnder {
                for index in [label] + noneLines { lines[index] = "" }
            }
            label = nil
            noneLines = []
            hiddenUnder = false
            visibleUnder = false
        }
        for index in lines.indices {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                close()
                let marks = line.prefix(while: { $0 == "#" })
                // "## Aufgaben" opens a tasks section; "#budget #q3" is a line of tags and only ends one.
                if marks.count <= 6, line.dropFirst(marks.count).first?.isWhitespace == true,
                   classify(line.dropFirst(marks.count).trimmingCharacters(in: .whitespaces)) == .tasks {
                    label = index
                }
                continue
            }
            if hidden.contains(index) {
                lines[index] = ""
                hiddenUnder = true
            } else if bullet(of: line) == nil, isTaskLabel(line) {
                close()
                label = index
            } else if label != nil, saysNone(bullet(of: line).map { String(line.dropFirst($0.count)) } ?? line) {
                noneLines.append(index)
            } else {
                visibleUnder = true
            }
        }
        close()
        return lines.joined(separator: "\n")
    }

    /// "**Action Items:**" or "Nächste Schritte:" on a line of its own: a heading written as a paragraph.
    private static func isTaskLabel(_ line: String) -> Bool {
        guard line.count <= 40, line.hasSuffix(":") || line.hasPrefix("**") || line.hasPrefix("__") else { return false }
        let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "*_: "))
        guard !name.isEmpty, !name.contains(where: { ":*_".contains($0) }), name.split(separator: " ").count <= 4 else { return false }
        return classify(name) == .tasks
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
