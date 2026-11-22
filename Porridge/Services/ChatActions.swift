import Foundation
import SwiftData

// The chat can change entries, never on its own: the model proposes changes (native tool calls of a cloud model,
// or ACTION lines in the answer of an on-device one), they are checked against the entries the chat showed or the
// user named (`ChatActionResolver`), shown as cards to confirm, and only then made (`EntryActions`), with an undo.
// DESIGN.md "Chat actions" describes it.

// MARK: - What the model proposed

/// One change as the model wrote it, before it is checked: a name and its arguments as text.
struct ChatActionCall: Equatable {
    var name: String
    /// Single values ("entry": "3", "bowl": "Taxes", "todo": "true").
    var arguments: [String: String]
    /// Lists ("add": ["work", "q4"]).
    var lists: [String: [String]]

    init(name: String, arguments: [String: String] = [:], lists: [String: [String]] = [:]) {
        self.name = ChatActionCall.canonicalName(name)
        self.arguments = arguments
        self.lists = lists
    }

    /// From a JSON object: the arguments of a tool call (`name` given), or an ACTION object with its name in
    /// "action" (or "tool", or "name" with the arguments in "arguments").
    init?(name: String?, json: [String: Any]) {
        var object = json
        var resolved = name
        if resolved == nil {
            if let action = (json["action"] ?? json["tool"] ?? json["function"]) as? String {
                resolved = action
                for key in ["action", "tool", "function"] { object.removeValue(forKey: key) }
            } else if let named = json["name"] as? String {
                resolved = named
                object.removeValue(forKey: "name")
            }
        }
        // The arguments nested: {"name": "...", "arguments": {...}}, or as a JSON string.
        for key in ["arguments", "args", "parameters", "input"] {
            if let inner = object[key] as? [String: Any] {
                object = inner
                break
            }
            if let text = object[key] as? String, let data = text.data(using: .utf8),
               let inner = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                object = inner
                break
            }
        }
        guard let resolved, !resolved.isEmpty else { return nil }
        var arguments: [String: String] = [:]
        var lists: [String: [String]] = [:]
        for (key, value) in object {
            let key = key.lowercased()
            switch value {
            case let list as [Any]: lists[key] = list.compactMap(ChatActionCall.text)
            case is NSNull: continue
            default: if let text = ChatActionCall.text(value) { arguments[key] = text }
            }
        }
        self.init(name: resolved, arguments: arguments, lists: lists)
    }

    private static func text(_ value: Any) -> String? {
        switch value {
        case let text as String: return text
        case let number as NSNumber:
            // A JSON true is an NSNumber too.
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.doubleValue == number.doubleValue.rounded() ? String(number.intValue) : number.stringValue
        default: return nil
        }
    }

    /// The first argument of these names that is there.
    func value(_ keys: String...) -> String? {
        for key in keys {
            if let value = arguments[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { return value }
        }
        return nil
    }

    /// A list argument; a single value is read as a comma-separated list.
    func list(_ keys: String...) -> [String] {
        for key in keys {
            if let list = lists[key] { return list }
            if let value = arguments[key] { return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        }
        return []
    }

    /// The names a small model writes for the same thing.
    static let aliases: [String: String] = [
        "move": "move_to_bowl", "file": "move_to_bowl", "move_entry": "move_to_bowl", "file_into_bowl": "move_to_bowl",
        "move_to_inbox": "move_to_bowl", "add_to_bowl": "move_to_bowl", "set_bowl": "move_to_bowl",
        "new_bowl": "create_bowl", "add_bowl": "create_bowl", "make_bowl": "create_bowl",
        "todo": "set_todo", "make_todo": "set_todo", "mark_done": "set_todo", "complete": "set_todo", "done": "set_todo",
        "tags": "set_tags", "tag": "set_tags", "add_tags": "set_tags", "add_tag": "set_tags", "remove_tags": "set_tags", "remove_tag": "set_tags",
        "document": "set_document_info", "set_document": "set_document_info", "correct_document": "set_document_info",
        "update_document": "set_document_info", "edit_document": "set_document_info",
        "note": "create_note", "new_note": "create_note", "add_note": "create_note", "create_todo": "create_note", "new_todo": "create_note",
    ]

    static func canonicalName(_ raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "`\"'")))
            .lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        return aliases[name] ?? name
    }
}

// MARK: - The tools

/// The changes the chat offers the model, described once: as tools for cloud models, as ACTION lines for the others.
enum ChatActionTools {
    struct Tool {
        let name: String
        let description: String
        /// JSON Schema of the arguments (the subset every provider accepts).
        let parameters: [String: Any]
    }

    private static func object(_ properties: [String: [String: Any]], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    private static let entry: [String: Any] = ["type": "string", "description": "The number of the entry in brackets, like \"3\"."]

    static let all: [Tool] = [
        Tool(name: "move_to_bowl", description: "Put an entry into a bowl (an entry is in at most one bowl: this replaces it). Bowl \"Inbox\" takes it out of its bowl. A bowl that does not exist yet is made.",
             parameters: object(["entry": entry, "bowl": ["type": "string", "description": "The bowl's name, or \"Inbox\"."]], required: ["entry", "bowl"])),
        Tool(name: "create_bowl", description: "Make a new, empty bowl.",
             parameters: object(["name": ["type": "string"]], required: ["name"])),
        Tool(name: "set_todo", description: "Make an entry a to-do (state \"open\") or mark it done (state \"done\"), optionally with a due day. Links, files and meetings cannot be to-dos.",
             parameters: object([
                "entry": entry,
                "state": ["type": "string", "enum": ["open", "done"]],
                "due": ["type": "string", "description": "Due day as yyyy-MM-dd, or \"none\" to remove it. Leave out to keep it."],
             ], required: ["entry", "state"])),
        Tool(name: "set_tags", description: "Add and remove tags of an entry.",
             parameters: object([
                "entry": entry,
                "add": ["type": "array", "items": ["type": "string"]],
                "remove": ["type": "array", "items": ["type": "string"]],
             ], required: ["entry"])),
        Tool(name: "set_document_info", description: "Correct what a document (a stored PDF, scan or file) is. Give only the fields to change.",
             parameters: object([
                "entry": entry,
                "kind": ["type": "string", "enum": DocumentKind.allCases.map(\.rawValue)],
                "sender": ["type": "string"],
                "date": ["type": "string", "description": "The date on the document, yyyy-MM-dd."],
                "amount": ["type": "string", "description": "The total, like \"119.00 EUR\"."],
             ], required: ["entry"])),
        Tool(name: "create_note", description: "Write a new note, or a to-do with todo true. Optionally into a bowl.",
             parameters: object([
                "title": ["type": "string"],
                "text": ["type": "string"],
                "bowl": ["type": "string"],
                "todo": ["type": "boolean"],
                "due": ["type": "string", "description": "Due day of a to-do, yyyy-MM-dd."],
             ], required: ["title"])),
    ]

    static var names: Set<String> { Set(all.map(\.name)) }

    /// Whether a question asks for a change (German and English): an on-device model is only told about actions then,
    /// so its little room and attention go to answering otherwise.
    static func asksForChange(_ question: String) -> Bool {
        let words = question.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init)
        let stems = [
            "verschieb", "schieb", "leg", "pack", "ablege", "einsortier", "sortier", "ordne", "verschiebe", "move", "file", "put",
            "erstell", "anleg", "mach", "create", "make", "add", "hinzufüg", "füg", "schreib", "write", "notier",
            "markier", "mark", "abhak", "hak", "erledig", "done", "complete", "tick",
            "tag", "tagg", "entfern", "remove", "lösch",
            "korrigier", "änder", "setz", "correct", "change", "fix", "set", "update",
        ]
        return words.contains { word in stems.contains { word.hasPrefix($0) } }
    }

    /// The note in the system prompt. `inline`: the model writes ACTION lines (no native tools).
    static func promptNote(inline: Bool) -> String {
        var note = """
        You can also propose changes; they run only after the user confirms them in the app: move an entry into a bowl (each entry is in at most one bowl), create a bowl, make an entry a to-do or mark it done (with a due day), add or remove tags, correct a document's kind, sender, date or amount, and create a note or to-do. Propose a change only when the user asks for one. Use only entries listed here, by their number. When it is unclear which entry or bowl is meant, ask instead of proposing. Nothing can be deleted or archived; links, files and meetings never become to-dos. Say in one short sentence what you propose; do not claim it is done.
        """
        if inline {
            note += """

            Write each change on a line of its own at the end of the answer, exactly like:
            ACTION: {"action": "move_to_bowl", "entry": "3", "bowl": "Taxes"}
            Actions: move_to_bowl(entry, bowl), create_bowl(name), set_todo(entry, state "open"|"done", due yyyy-MM-dd), set_tags(entry, add [..], remove [..]), set_document_info(entry, kind, sender, date, amount), create_note(title, text, bowl, todo true|false, due).
            """
        } else {
            note += " Use the tools for it."
        }
        return note
    }
}

// MARK: - ACTION lines in an answer

/// Reads the changes an on-device model wrote into its answer, and takes them out of the text:
/// `ACTION: {"action": "set_todo", "entry": "2", "state": "done"}`, `ACTION: set_todo entry=2 state=done`, or a fenced
/// ```action block with one JSON object (or a list of them).
enum ChatActionParser {
    static func extract(from answer: String) -> (text: String, calls: [ChatActionCall]) {
        var calls: [ChatActionCall] = []
        var kept: [String] = []
        let lines = answer.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A fenced block of actions: ```action, or ```json with "action" in it.
            if trimmed.hasPrefix("```") {
                let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                if let end = lines[(index + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
                    let body = lines[(index + 1)..<end].joined(separator: "\n")
                    let found = tag.hasPrefix("action") || tag == "json" || tag.isEmpty ? jsonCalls(body) : []
                    if !found.isEmpty || tag.hasPrefix("action") {
                        calls += found + (found.isEmpty ? body.components(separatedBy: "\n").compactMap(lineCall) : [])
                        index = end + 1
                        continue
                    }
                }
            }
            if let payload = actionPayload(trimmed) {
                // A JSON object may go on over the next lines.
                var text = payload
                var next = index + 1
                if text.hasPrefix("{") {
                    while !isBalanced(text), next < lines.count, next - index < 12 {
                        text += "\n" + lines[next]
                        next += 1
                    }
                }
                if let call = text.hasPrefix("{") || text.hasPrefix("[") ? jsonCalls(text).first : lineCall(text) {
                    calls.append(call)
                    index = next
                    continue
                }
            }
            kept.append(line)
            index += 1
        }
        var text = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // "Actions:" left alone at the end, or a heading over the lines that were taken out.
        for tail in ["actions:", "action:", "aktionen:", "**actions:**"] where text.lowercased().hasSuffix(tail) {
            text = String(text.dropLast(tail.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (text, calls)
    }

    /// What follows "ACTION:" on a line ("- `ACTION: …`", "**ACTION**: …" too).
    private static func actionPayload(_ line: String) -> String? {
        var rest = Substring(line)
        while let first = rest.first, "-*•>` ".contains(first) { rest = rest.dropFirst() }
        guard rest.lowercased().hasPrefix("action") else { return nil }
        rest = rest.dropFirst("action".count)
        // Not "actions are …" in a sentence: the word is followed by a colon (or straight by the JSON).
        while let first = rest.first, "*` ".contains(first) { rest = rest.dropFirst() }
        if rest.first == ":" {
            rest = rest.dropFirst()
        } else if rest.first != "{" {
            // "ACTION set_todo entry=2": the word is followed by the name of an action.
            let word = rest.prefix { $0.isLetter || $0 == "_" }
            guard !word.isEmpty, ChatActionTools.names.contains(ChatActionCall.canonicalName(String(word))) else { return nil }
        }
        var payload = rest.trimmingCharacters(in: .whitespaces)
        while payload.hasSuffix("`") { payload.removeLast() }
        return payload.isEmpty ? nil : payload
    }

    private static func isBalanced(_ text: String) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for character in text {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { inString.toggle(); continue }
            guard !inString else { continue }
            if character == "{" || character == "[" { depth += 1 }
            if character == "}" || character == "]" { depth -= 1 }
        }
        return depth <= 0
    }

    /// JSON as small models write it: typographic quotes and trailing commas are forgiven.
    static func jsonCalls(_ raw: String) -> [ChatActionCall] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for (from, to) in [("“", "\""), ("”", "\""), ("„", "\""), ("’", "'")] { text = text.replacingOccurrences(of: from, with: to) }
        text = text.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
        // Several objects one after the other, one per line.
        if !text.hasPrefix("["), text.contains("}\n{") || text.contains("}\n\n{") {
            text = "[" + text.replacingOccurrences(of: #"\}\s*\n\s*\{"#, with: "},{", options: .regularExpression) + "]"
        }
        guard let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let objects = (json as? [[String: Any]]) ?? (json as? [String: Any]).map { [$0] } ?? []
        return objects.compactMap { ChatActionCall(name: nil, json: $0) }
    }

    /// `set_todo entry=2 state=done` or `move_to_bowl(entry: 3, bowl: "Taxes")`.
    static func lineCall(_ raw: String) -> ChatActionCall? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let nameEnd = text.firstIndex(where: { $0 == " " || $0 == "(" || $0 == ":" }) ?? text.endIndex
        let name = String(text[..<nameEnd])
        text = String(text[nameEnd...]).trimmingCharacters(in: CharacterSet(charactersIn: " ():"))
        guard ChatActionTools.names.contains(ChatActionCall.canonicalName(name)) else { return nil }
        var arguments: [String: String] = [:]
        let pattern = try! NSRegularExpression(pattern: #"([A-Za-z_]+)\s*[=:]\s*("[^"]*"|'[^']*'|\[[^\]]*\]|[^,\s)]+)"#)
        var lists: [String: [String]] = [:]
        let ns = text as NSString
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            var value = ns.substring(with: match.range(at: 2))
            if value.hasPrefix("[") {
                lists[key] = value.dropFirst().dropLast().split(separator: ",")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }.filter { !$0.isEmpty }
                continue
            }
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            arguments[key] = value
        }
        return ChatActionCall(name: name, arguments: arguments, lists: lists)
    }
}

// MARK: - A checked change

/// A change the chat proposes, checked and ready to confirm: what it does, and how the card names it.
struct ChatAction: Codable, Hashable, Identifiable {
    enum BowlTarget: Codable, Hashable {
        case inbox
        /// `Projects.key` of a bowl that is there.
        case existing(String)
        /// A bowl that is made on confirming (or found, when it was made meanwhile).
        case new(String)
    }

    enum Operation: Codable, Hashable {
        case move(note: UUID, bowl: BowlTarget)
        case createBowl(name: String)
        /// `due`: a day key, `Todos.clearedDue` to take it away, nil to keep it.
        case todo(note: UUID, done: Bool, due: String?)
        case tags(note: UUID, add: [String], remove: [String])
        /// `kind`: `DocumentKind` raw value; `day` "yyyy-MM-dd"; `amount` "119.00 EUR". Nil fields stay.
        case document(note: UUID, kind: String?, day: String?, sender: String?, amount: String?)
        case createNote(title: String, text: String, bowl: BowlTarget?, todo: Bool, due: String?)

        /// The entry the change is about; nil for what it makes.
        var noteID: UUID? {
            switch self {
            case .move(let note, _), .todo(let note, _, _), .tags(let note, _, _), .document(let note, _, _, _, _): note
            case .createBowl, .createNote: nil
            }
        }
    }

    enum Status: String, Codable {
        case pending, done, cancelled, failed, undone
    }

    var id = UUID()
    var operation: Operation
    /// What the card says it does: "Move to Bowl “Taxes”".
    var title: String
    /// What it is done to: the entry's title.
    var subject: String?
    var symbol: String
    var status: Status = .pending
    /// Why it could not be made.
    var failure: String?
}

// MARK: - Checking what the model proposed

/// What the chat showed and the user said: the entries an action may touch, and the bowls it may name.
struct ChatActionScope {
    /// The entries by the numbers the model read them under: `numbered[n - 1]` is entry [n].
    var numbered: [UUID]
    /// Every entry the chat showed in this answer or earlier ones.
    var referenced: Set<UUID>
    /// The question: an entry it names by its title may be changed even when the chat did not show it.
    var question: String
    /// The living entries the chat is about.
    var notes: [Note]
    var bowls: [NoteFolder]
    var now = Date()
}

enum ChatActionResolver {
    /// At most this many changes per answer.
    static let limit = 10

    /// Checks the calls: the entries must be ones the chat showed or the user named, the change must fit the entry
    /// (no to-do from a link), and must change something. What is unclear becomes a question back; what does not fit
    /// a remark.
    static func resolve(_ calls: [ChatActionCall], in scope: ChatActionScope) -> (actions: [ChatAction], remarks: [String]) {
        var actions: [ChatAction] = []
        var remarks: [String] = []
        let byID = Dictionary(scope.notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for call in calls.prefix(limit) {
            switch resolve(call, scope: scope, byID: byID) {
            case .success(let action):
                if !actions.contains(where: { $0.operation == action.operation }) { actions.append(action) }
            case .failure(let problem):
                if !remarks.contains(problem.text) { remarks.append(problem.text) }
            }
        }
        return (actions, remarks)
    }

    struct Problem: Error { let text: String }

    private static func resolve(_ call: ChatActionCall, scope: ChatActionScope, byID: [UUID: Note]) -> Result<ChatAction, Problem> {
        do {
            return .success(try action(for: call, scope: scope, byID: byID))
        } catch let problem as Problem {
            return .failure(problem)
        } catch {
            return .failure(Problem(text: error.localizedDescription))
        }
    }

    private static func action(for call: ChatActionCall, scope: ChatActionScope, byID: [UUID: Note]) throws -> ChatAction {
        switch call.name {
        case "move_to_bowl":
            let note = try entry(call, scope: scope, byID: byID)
            guard let name = call.value("bowl", "bowl_name", "to", "name", "target") else { throw Problem(text: "Which bowl should «\(note.displayTitle)» go into?") }
            let target = try bowl(name, scope: scope)
            let current = note.projectIDs
            switch target {
            case .inbox: if current.isEmpty { throw Problem(text: "«\(note.displayTitle)» is already in the Inbox.") }
            case .existing(let key): if current == [key] { throw Problem(text: "«\(note.displayTitle)» is already in Bowl “\(bowlName(key, scope: scope))”.") }
            case .new: break
            }
            return ChatAction(operation: .move(note: note.id, bowl: target), title: moveTitle(target, scope: scope), subject: note.displayTitle, symbol: "tray.and.arrow.down")
        case "create_bowl":
            guard let name = call.value("name", "bowl", "title") else { throw Problem(text: "What should the new bowl be called?") }
            if let existing = scope.bowls.first(where: { EntryActions.nameKey($0.name) == EntryActions.nameKey(name) }) {
                throw Problem(text: "Bowl “\(existing.name)” already exists.")
            }
            return ChatAction(operation: .createBowl(name: name.trimmingCharacters(in: .whitespacesAndNewlines)), title: "Create Bowl “\(name)”", symbol: "folder.badge.plus")
        case "set_todo":
            let note = try entry(call, scope: scope, byID: byID)
            guard note.isTodo || note.canBeTodo else {
                throw Problem(text: "«\(note.displayTitle)» is \(note.isLink ? "a link" : note.isRecording ? "a meeting" : "a saved file"): it cannot be a to-do.")
            }
            let state = (call.value("state", "status") ?? (call.value("done") == "true" ? "done" : "open")).lowercased()
            let done = ["done", "erledigt", "completed", "complete", "closed", "true", "checked"].contains(state)
            var due: String?
            if let raw = call.value("due", "due_day", "due_date", "date") {
                if ["none", "null", "remove", "no", "keine", "-"].contains(raw.lowercased()) {
                    due = note.todoDue == nil ? nil : Todos.clearedDue
                } else if let key = day(raw, now: scope.now) {
                    due = key == note.todoDue ? nil : key
                } else {
                    throw Problem(text: "I could not read the due day “\(raw)”.")
                }
            }
            if note.isTodo, note.isDone == done, due == nil {
                throw Problem(text: "«\(note.displayTitle)» already is \(done ? "done" : "an open to-do").")
            }
            var title = done ? (note.isTodo ? "Mark Done" : "Make To-do, Done") : (note.isTodo ? "Mark Open" : "Make To-do")
            if let due { title += due == Todos.clearedDue ? ", no due day" : ", due " + Todos.dueText(due) }
            return ChatAction(operation: .todo(note: note.id, done: done, due: due), title: title, subject: note.displayTitle, symbol: done ? "checkmark.circle" : "checklist")
        case "set_tags":
            let note = try entry(call, scope: scope, byID: byID)
            let existing = Set(note.tags.map { $0.lowercased() })
            let labels = Set(note.labels.map { $0.lowercased() })
            let add = unique(call.list("add", "tags", "tag", "add_tags").map(Note.cleanTag)).filter { !$0.isEmpty && !existing.contains($0.lowercased()) }
            let wanted = unique(call.list("remove", "remove_tags", "delete").map(Note.cleanTag)).filter { !$0.isEmpty }
            let remove = wanted.filter { labels.contains($0.lowercased()) }
            if add.isEmpty, remove.isEmpty {
                if let inline = wanted.first(where: { existing.contains($0.lowercased()) }) {
                    throw Problem(text: "#\(inline) is written in the text of «\(note.displayTitle)»: remove it there.")
                }
                throw Problem(text: "«\(note.displayTitle)» already has these tags.")
            }
            var parts: [String] = []
            if !add.isEmpty { parts.append("Add " + add.map { "#" + $0 }.joined(separator: " ")) }
            if !remove.isEmpty { parts.append("Remove " + remove.map { "#" + $0 }.joined(separator: " ")) }
            return ChatAction(operation: .tags(note: note.id, add: add, remove: remove), title: parts.joined(separator: ", "), subject: note.displayTitle, symbol: "tag")
        case "set_document_info":
            let note = try entry(call, scope: scope, byID: byID)
            guard note.isStored, !note.attachments.isEmpty else { throw Problem(text: "«\(note.displayTitle)» is not a document.") }
            let current = note.documentInfo ?? DocumentInfo()
            var kind: DocumentKind?
            if let raw = call.value("kind", "type", "document_kind") {
                guard let found = DocumentKind.named(raw) ?? DocumentKind.allCases.first(where: { $0.title.lowercased() == raw.lowercased() }) else {
                    throw Problem(text: "“\(raw)” is not a document kind I know.")
                }
                kind = found == current.kind ? nil : found
            }
            var documentDay: String?
            if let raw = call.value("date", "day", "document_date") {
                guard let key = day(raw, now: scope.now) else { throw Problem(text: "I could not read the date “\(raw)”.") }
                documentDay = key == current.day ? nil : key
            }
            var sender = call.value("sender", "correspondent", "from")
            if sender == current.correspondent { sender = nil }
            var amount: String?
            if let raw = call.value("amount", "total", "sum") {
                guard let value = self.amount(raw) else { throw Problem(text: "I could not read the amount “\(raw)”.") }
                amount = value == current.amount ? nil : value
            }
            guard kind != nil || documentDay != nil || sender != nil || amount != nil else {
                throw Problem(text: "«\(note.displayTitle)» already says so.")
            }
            var parts: [String] = []
            if let kind { parts.append(kind.title) }
            if let sender { parts.append("from " + sender) }
            if let documentDay, let date = DocumentInfo.date(fromDay: documentDay) { parts.append("dated " + date.formatted(date: .abbreviated, time: .omitted)) }
            if let amount { parts.append(DocumentInfo(amount: amount).amountText ?? amount) }
            return ChatAction(
                operation: .document(note: note.id, kind: kind?.rawValue, day: documentDay, sender: sender, amount: amount),
                title: "Set Document: " + parts.joined(separator: ", "), subject: note.displayTitle, symbol: "doc.text.magnifyingglass"
            )
        case "create_note":
            let title = call.value("title", "name") ?? ""
            let text = call.value("text", "body", "content") ?? ""
            guard !title.isEmpty || !text.isEmpty else { throw Problem(text: "What should the new note say?") }
            let target = try call.value("bowl").map { try bowl($0, scope: scope) }
            let todo = ["true", "yes", "1", "open"].contains((call.value("todo", "is_todo", "state") ?? "").lowercased()) || call.value("due") != nil
            var due: String?
            if let raw = call.value("due", "due_day", "due_date") {
                guard let key = day(raw, now: scope.now) else { throw Problem(text: "I could not read the due day “\(raw)”.") }
                due = key
            }
            var heading = todo ? "Create To-do" : "Create Note"
            if let due { heading += ", due " + Todos.dueText(due) }
            if let target, target != .inbox { heading += " in " + bowlLabel(target, scope: scope) }
            let shown = title.isEmpty ? String(text.prefix(60)) : title
            return ChatAction(
                operation: .createNote(title: title, text: text, bowl: target == .inbox ? nil : target, todo: todo, due: due),
                title: heading, subject: shown, symbol: todo ? "checklist" : "square.and.pencil"
            )
        case "delete", "delete_entry", "delete_note", "archive", "archive_note", "trash", "delete_bowl":
            throw Problem(text: "The chat cannot delete or archive anything.")
        default:
            throw Problem(text: "I cannot do “\(call.name)” from the chat.")
        }
    }

    // MARK: Entries

    /// The entry an action names: by its number, else by its title among the entries the chat showed, else among
    /// all entries when the question names that title. Several that fit make a question back.
    static func entry(_ call: ChatActionCall, scope: ChatActionScope, byID: [UUID: Note]) throws -> Note {
        guard let raw = call.value("entry", "item", "number", "note", "id", "entry_id", "title") else {
            throw Problem(text: "Which entry do you mean?")
        }
        let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]#() «»\"'"))
        // "3", "[3]", "#3", or "[3] «Title»".
        let start = raw.trimmingCharacters(in: .whitespaces)
        let leading = start.hasPrefix("[") ? Int(String(start.dropFirst().prefix { $0.isNumber })) : nil
        if let number = Int(cleaned) ?? leading {
            guard number >= 1, number <= scope.numbered.count, let note = byID[scope.numbered[number - 1]] else {
                throw Problem(text: "Which entry do you mean? I have no entry [\(number)].")
            }
            return note
        }
        if let id = UUID(uuidString: cleaned) {
            guard scope.referenced.contains(id), let note = byID[id] else { throw Problem(text: "Which entry do you mean?") }
            return note
        }
        let key = EntryActions.nameKey(cleaned)
        let shown = scope.referenced.compactMap { byID[$0] }
        var fits = shown.filter { EntryActions.nameKey($0.displayTitle) == key }
        if fits.isEmpty { fits = shown.filter { EntryActions.nameKey($0.displayTitle).contains(key) } }
        // Named by the user: its title is in the question.
        if fits.isEmpty, EntryActions.nameKey(scope.question).contains(key) {
            fits = scope.notes.filter { EntryActions.nameKey($0.displayTitle) == key }
        }
        guard !fits.isEmpty else { throw Problem(text: "I could not find the entry “\(cleaned)”. Which one do you mean?") }
        guard fits.count == 1 else {
            let names = fits.prefix(4).map { "«\($0.displayTitle)» (\($0.createdAt.formatted(date: .abbreviated, time: .omitted)))" }
            throw Problem(text: "Which “\(cleaned)” do you mean: " + names.joined(separator: ", ") + "?")
        }
        return fits[0]
    }

    // MARK: Bowls

    static func bowl(_ raw: String, scope: ChatActionScope) throws -> ChatAction.BowlTarget {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "“”\"'«»")))
        let key = EntryActions.nameKey(name)
        guard !key.isEmpty else { throw Problem(text: "Which bowl do you mean?") }
        if ["inbox", "eingang", "posteingang", "none", "no bowl", "kein bowl", "keine bowl"].contains(key) { return .inbox }
        if let id = UUID(uuidString: name), let bowl = scope.bowls.first(where: { $0.id == id }) {
            guard !bowl.isArchived else { throw Problem(text: "Bowl “\(bowl.name)” is archived.") }
            return .existing(Projects.key(bowl))
        }
        let named = scope.bowls.filter { EntryActions.nameKey($0.name) == key }
        let active = named.filter { !$0.isArchived }
        if active.count > 1 { throw Problem(text: "There are \(active.count) bowls named “\(active[0].name)”. Which one do you mean?") }
        if let bowl = active.first { return .existing(Projects.key(bowl)) }
        if let archived = named.first { throw Problem(text: "Bowl “\(archived.name)” is archived.") }
        return .new(name)
    }

    static func bowlName(_ key: String, scope: ChatActionScope) -> String {
        scope.bowls.first { Projects.key($0) == key }?.name ?? "?"
    }

    static func bowlLabel(_ target: ChatAction.BowlTarget, scope: ChatActionScope) -> String {
        switch target {
        case .inbox: "Inbox"
        case .existing(let key): "Bowl “\(bowlName(key, scope: scope))”"
        case .new(let name): "new Bowl “\(name)”"
        }
    }

    private static func moveTitle(_ target: ChatAction.BowlTarget, scope: ChatActionScope) -> String {
        target == .inbox ? "Move to Inbox" : "Move to " + bowlLabel(target, scope: scope)
    }

    // MARK: Values

    private static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.lowercased()).inserted }
    }

    /// A day as "yyyy-MM-dd": written so, as "17.11.2026" / "17.11.", or as today, tomorrow (German too).
    static func day(_ raw: String, now: Date, calendar: Calendar = .current) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let offsets = ["today": 0, "heute": 0, "tomorrow": 1, "morgen": 1, "übermorgen": 2, "day after tomorrow": 2, "yesterday": -1, "gestern": -1]
        if let offset = offsets[text], let date = calendar.date(byAdding: .day, value: offset, to: now) { return Todos.dueKey(date, calendar: calendar) }
        let numbers = text.split { !$0.isNumber }.compactMap { Int($0) }
        if text.contains("-"), numbers.count == 3, numbers[0] > 31 { return DocumentInfo.dayKey(year: numbers[0], month: numbers[1], day: numbers[2]) }
        if text.contains("."), numbers.count >= 2 {
            var year = numbers.count >= 3 ? numbers[2] : calendar.component(.year, from: now)
            if year < 100 { year += 2000 }
            return DocumentInfo.dayKey(year: year, month: numbers[1], day: numbers[0])
        }
        if text.contains("/"), numbers.count == 3 {
            // 11/17/2026 (month first) unless the first number cannot be a month.
            let (month, day) = numbers[0] > 12 ? (numbers[1], numbers[0]) : (numbers[0], numbers[1])
            return DocumentInfo.dayKey(year: numbers[2] < 100 ? numbers[2] + 2000 : numbers[2], month: month, day: day)
        }
        return nil
    }

    /// An amount as `DocumentInfo` keeps it, "119.00 EUR": from "119,00 €", "EUR 1.234,56", "$10.63", "119".
    static func amount(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let symbols: [String: String] = ["€": "EUR", "$": "USD", "£": "GBP", "¥": "JPY", "chf": "CHF", "fr.": "CHF"]
        var currency: String?
        for (symbol, code) in symbols where text.lowercased().contains(symbol) { currency = code }
        if let code = text.uppercased().split(whereSeparator: { !$0.isLetter }).map(String.init).first(where: { $0.count == 3 && Locale.commonISOCurrencyCodes.contains($0) }) {
            currency = code
        }
        var digits = text.filter { $0.isNumber || $0 == "," || $0 == "." || $0 == "-" }
        guard digits.contains(where: \.isNumber) else { return nil }
        // The last separator with one or two digits after it is the decimal mark; the others group thousands.
        if let last = digits.lastIndex(where: { $0 == "," || $0 == "." }), digits.distance(from: last, to: digits.endIndex) - 1 <= 2 {
            let whole = digits[..<last].filter { $0.isNumber || $0 == "-" }
            let fraction = digits[digits.index(after: last)...]
            digits = whole + "." + String(fraction)
        } else {
            digits = digits.filter { $0.isNumber || $0 == "-" }
        }
        guard let value = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let number = NSDecimalNumber(decimal: value)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        guard let plain = formatter.string(from: number) else { return nil }
        return plain + (currency.map { " " + $0 } ?? "")
    }
}

// MARK: - Making a confirmed change

@MainActor
enum ChatActionRunner {
    /// Makes the change; throws when it no longer fits (the entry is gone, it changed meanwhile).
    static func run(_ action: ChatAction, in context: ModelContext, now: Date = Date()) throws -> EntryActions.Undo {
        func note(_ id: UUID) throws -> Note {
            guard let note = EntryActions.note(id, in: context) else { throw EntryActions.Failure.entryGone }
            return note
        }
        switch action.operation {
        case .move(let id, let target):
            let entry = try note(id)
            var undo = EntryActions.Undo()
            let key: String?
            switch target {
            case .inbox: key = nil
            case .existing(let existing): key = existing
            case .new(let name):
                let made = try EntryActions.bowl(named: name, in: context)
                undo.append(made.undo)
                key = Projects.key(made.bowl)
            }
            do {
                undo.append(try EntryActions.move(entry, toBowl: key, in: context, now: now))
            } catch {
                EntryActions.undo(undo, in: context)
                throw error
            }
            return undo
        case .createBowl(let name):
            return try EntryActions.createBowl(named: name, in: context).undo
        case .todo(let id, let done, let due):
            let change: EntryActions.DueChange? = due.map { $0 == Todos.clearedDue ? .clear : .set($0) }
            return try EntryActions.setTodo(try note(id), done: done, due: change, in: context)
        case .tags(let id, let add, let remove):
            return try EntryActions.setTags(try note(id), add: add, remove: remove, in: context, now: now)
        case .document(let id, let kind, let day, let sender, let amount):
            let change = EntryActions.DocumentChange(kind: kind.flatMap(DocumentKind.init(rawValue:)), day: day, sender: sender, amount: amount)
            return try EntryActions.setDocumentInfo(try note(id), change, in: context)
        case .createNote(let title, let text, let target, let todo, let due):
            var undo = EntryActions.Undo()
            var key: String?
            switch target {
            case .existing(let existing): key = existing
            case .new(let name):
                let made = try EntryActions.bowl(named: name, in: context)
                undo.append(made.undo)
                key = Projects.key(made.bowl)
            case .inbox, nil: key = nil
            }
            undo.append(try EntryActions.createNote(title: title, text: text, bowl: key, todo: todo, due: due, in: context, now: now).undo)
            return undo
        }
    }

    /// Runs several, bowls first (a move may go into one made in the same go). Returns the way back from all that
    /// was made, and the actions with their new state.
    static func run(_ actions: [ChatAction], in context: ModelContext, now: Date = Date()) -> (undo: EntryActions.Undo, actions: [ChatAction]) {
        var undo = EntryActions.Undo()
        var result = actions
        let order = actions.indices.sorted { first, second in
            let a = actions[first].operation.isCreateBowl ? 0 : 1
            let b = actions[second].operation.isCreateBowl ? 0 : 1
            return a != b ? a < b : first < second
        }
        for index in order where result[index].status == .pending {
            do {
                undo.append(try run(result[index], in: context, now: now))
                result[index].status = .done
                result[index].failure = nil
            } catch {
                result[index].status = .failed
                result[index].failure = error.localizedDescription
            }
        }
        return (undo, result)
    }
}

extension ChatAction.Operation {
    var isCreateBowl: Bool {
        if case .createBowl = self { return true }
        return false
    }
}

// MARK: - The way back, offered for a moment

/// What was just made from the chat, with its undo: shown as a toast for `duration` seconds.
struct ChatUndoToast: Identifiable {
    static let duration: Double = 8

    let id = UUID()
    let entryID: UUID
    let actionIDs: [UUID]
    let message: String
    let undo: EntryActions.Undo

    /// "«Invoice»: Move to Bowl “Taxes”" for one change, "3 changes made" for several.
    static func message(for done: [ChatAction]) -> String {
        guard done.count == 1, let action = done.first else { return "\(done.count) changes made" }
        let subject = action.subject.map { "«\($0)»: " } ?? ""
        return subject + action.title
    }
}

// MARK: - Kept on this device

/// The proposed changes of the answers and their state, on this device only (the chats are not synced either). Not
/// in the store: no field of the synced models changes. The newest answers' are kept.
enum ChatActionStore {
    private static let key = "chatActions"
    static let keep = 80

    private struct Record: Codable {
        let entryID: UUID
        let actions: [ChatAction]
        let at: Date
    }

    static func load(defaults: UserDefaults = .standard) -> [UUID: [ChatAction]] {
        guard let data = defaults.data(forKey: key), let records = try? JSONDecoder().decode([Record].self, from: data) else { return [:] }
        return Dictionary(records.map { ($0.entryID, $0.actions) }, uniquingKeysWith: { _, last in last })
    }

    static func save(_ actions: [UUID: [ChatAction]], defaults: UserDefaults = .standard) {
        var stamps: [UUID: Date] = [:]
        if let data = defaults.data(forKey: key), let records = try? JSONDecoder().decode([Record].self, from: data) {
            for record in records { stamps[record.entryID] = record.at }
        }
        let now = Date()
        let records = actions.map { Record(entryID: $0.key, actions: $0.value, at: stamps[$0.key] ?? now) }
            .sorted { $0.at > $1.at }
            .prefix(keep)
        defaults.set(try? JSONEncoder().encode(Array(records)), forKey: key)
    }
}
