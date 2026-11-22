import Foundation
import SwiftData

/// The settings of the MCP server (Mac Settings › MCP Server). Off by default; the write tools each need their own
/// "Allow changes". Kept in the app's defaults, which the stdio bridge (`porridge --mcp`) reads too.
enum MCPSettings {
    static let enabledKey = "mcpServerEnabled"
    static let allowCreateKey = "mcpAllowCreateNote"
    static let allowMoveKey = "mcpAllowMoveToBowl"
    static let tokenKey = "mcpServerToken"
    static let portKey = "mcpServerPort"
    static let defaultPort = 52_830

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var port: Int {
        let stored = UserDefaults.standard.integer(forKey: portKey)
        return (1024...65_535).contains(stored) ? stored : defaultPort
    }

    static var permissions: MCPPermissions {
        MCPPermissions(
            createNote: UserDefaults.standard.bool(forKey: allowCreateKey),
            moveToBowl: UserDefaults.standard.bool(forKey: allowMoveKey)
        )
    }
}

/// Which changes MCP clients may make. There is no delete tool at all.
struct MCPPermissions: Equatable {
    var createNote = false
    var moveToBowl = false
}

/// Porridge's MCP tools: reading the notes (search, entries, bowls, inbox, recent ones) and two small, safe changes
/// (a new note, an entry into another bowl). Works on a `ModelContext`; the passages for the search come from
/// `passages` (the app's `NoteIndex`, in tests cut from the notes directly).
@MainActor
final class MCPToolbox: MCPToolProvider {
    private let context: ModelContext
    private let permissions: () -> MCPPermissions
    private let passages: ([Note]) async -> [ChatChunk]
    private let queryVector: (String) async -> [Float]?
    private let now: () -> Date
    /// Long text fields (text, summary, transcript, page) are cut to this many characters unless asked otherwise.
    static let defaultMaxLength = 40_000

    init(
        context: ModelContext,
        permissions: @escaping () -> MCPPermissions,
        passages: @escaping ([Note]) async -> [ChatChunk] = { ChatRetrieval.chunks(from: $0) },
        queryVector: @escaping (String) async -> [Float]? = { _ in nil },
        now: @escaping () -> Date = Date.init
    ) {
        self.context = context
        self.permissions = permissions
        self.passages = passages
        self.queryVector = queryVector
        self.now = now
    }

    // MARK: Definitions

    static let kinds = ChatDocument.Kind.allCases.map(\.rawValue)

    static let readTools: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "search", title: "Search Porridge",
            description: """
            Searches the user's Porridge entries (notes, meetings, links, to-dos, images, files) by words and meaning, \
            narrowed by filters. With no query, the entries that pass the filters come newest first. Returns ids, \
            titles, kind, bowl, tags, a snippet and the best matching passage; read one in full with get_entry.
            """,
            inputSchema: object([
                "query": ["type": "string", "description": "Words to search for, in any language. May be empty when filters are given."],
                "kind": ["type": "string", "enum": .array(kinds.map(JSONValue.string)), "description": "Only entries of this kind."],
                "bowl": ["type": "string", "description": "Only entries in this bowl: its id or its name."],
                "inbox": ["type": "boolean", "description": "Only entries in the Inbox (in no bowl)."],
                "tag": ["type": "string", "description": "Only entries with this tag (with or without #)."],
                "document_kind": ["type": "string", "enum": .array(DocumentKind.allCases.map { .string($0.rawValue) }),
                                  "description": "Only documents (scanned or shared papers) of this kind."],
                "from": ["type": "string", "description": "Only entries dated on or after this day, yyyy-MM-dd (the date on a document, else when the entry was created)."],
                "to": ["type": "string", "description": "Only entries dated on or before this day, yyyy-MM-dd."],
                "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "How many results at most (default 20)."],
            ]),
            readOnly: true
        ),
        MCPToolDefinition(
            name: "get_entry", title: "Read an Entry",
            description: """
            Reads one entry in full: title, kind, dates, bowl, tags, its text (Markdown), summary, transcript with \
            speakers (meetings), page text (links), document details (kind, date, sender, amount), to-do state with \
            subtasks and the names of its files.
            """,
            inputSchema: object([
                "id": ["type": "string", "description": "The entry's id (from search and the lists)."],
                "max_length": ["type": "integer", "minimum": 500, "description": "Long fields are cut to this many characters (default 40000)."],
            ], required: ["id"]),
            readOnly: true
        ),
        MCPToolDefinition(
            name: "list_bowls", title: "List Bowls",
            description: "Lists the user's bowls (the topics entries are filed into; each entry is in one bowl at most) with their ids and how many entries each holds.",
            inputSchema: object([
                "include_archived": ["type": "boolean", "description": "Also list archived bowls (default false)."],
            ]),
            readOnly: true
        ),
        MCPToolDefinition(
            name: "list_inbox", title: "List the Inbox",
            description: "Lists what waits in the Inbox (entries in no bowl), newest first.",
            inputSchema: object([
                "limit": ["type": "integer", "minimum": 1, "maximum": 200, "description": "How many at most (default 50)."],
            ]),
            readOnly: true
        ),
        MCPToolDefinition(
            name: "recent_entries", title: "Recent Entries",
            description: "Lists the newest entries, or those changed last.",
            inputSchema: object([
                "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "How many at most (default 20)."],
                "kind": ["type": "string", "enum": .array(kinds.map(JSONValue.string)), "description": "Only entries of this kind."],
                "days": ["type": "integer", "minimum": 1, "description": "Only entries of the last this many days."],
                "order": ["type": "string", "enum": ["created", "updated"], "description": "created (default): newest first; updated: changed last first."],
            ]),
            readOnly: true
        ),
    ]

    static let createNoteTool = MCPToolDefinition(
        name: "create_note", title: "Create a Note",
        description: "Creates a new note in Porridge. It lands in the Inbox, or in the given bowl. Returns the new entry.",
        inputSchema: object([
            "text": ["type": "string", "description": "The note's text, Markdown (headings, lists, checklists; #words are tags)."],
            "title": ["type": "string", "description": "A title (optional)."],
            "bowl": ["type": "string", "description": "The bowl to put it in, by id or name (optional; default the Inbox)."],
        ], required: ["text"]),
        readOnly: false, idempotent: false
    )

    static let moveToBowlTool = MCPToolDefinition(
        name: "move_to_bowl", title: "Move to a Bowl",
        description: "Puts an entry into a bowl (in place of the one it is in: an entry is in one bowl at most), or back into the Inbox with to_inbox. Nothing is deleted.",
        inputSchema: object([
            "id": ["type": "string", "description": "The entry's id."],
            "bowl": ["type": "string", "description": "The bowl, by id or name."],
            "to_inbox": ["type": "boolean", "description": "Take the entry out of its bowl, back into the Inbox (instead of bowl)."],
        ], required: ["id"]),
        readOnly: false
    )

    private static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties), "additionalProperties": false]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }

    var tools: [MCPToolDefinition] {
        let allowed = permissions()
        return Self.readTools + (allowed.createNote ? [Self.createNoteTool] : []) + (allowed.moveToBowl ? [Self.moveToBowlTool] : [])
    }

    // MARK: Calling

    /// A wrong argument or a missing entry: answered as a tool error the model can read and correct.
    struct Failure: Error { let message: String }

    func call(_ name: String, arguments: [String: JSONValue]) async -> MCPToolResult? {
        do {
            switch name {
            case "search": return try await search(arguments)
            case "get_entry": return try getEntry(arguments)
            case "list_bowls": return listBowls(arguments)
            case "list_inbox": return try listInbox(arguments)
            case "recent_entries": return try recentEntries(arguments)
            case "create_note":
                guard permissions().createNote else { return .failure(Self.notAllowed("create_note", setting: "Create notes")) }
                return try createNote(arguments)
            case "move_to_bowl":
                guard permissions().moveToBowl else { return .failure(Self.notAllowed("move_to_bowl", setting: "Move entries to bowls")) }
                return try moveToBowl(arguments)
            default: return nil
            }
        } catch let failure as Failure {
            return .failure(failure.message)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    static func notAllowed(_ tool: String, setting: String) -> String {
        "\(tool) is turned off. The user can allow it in Porridge › Settings › MCP Server › Allow changes › \(setting)."
    }

    // MARK: Reading

    private func livingNotes() -> [Note] {
        ((try? context.fetch(FetchDescriptor<Note>())) ?? []).filter { !$0.isDeleted }
    }

    private func bowls() -> [NoteFolder] {
        (try? context.fetch(FetchDescriptor<NoteFolder>(sortBy: [SortDescriptor(\.name)]))) ?? []
    }

    private func bowlNames() -> [String: String] {
        Dictionary(bowls().map { (Projects.key($0), $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private func search(_ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let limit = try Self.limit(arguments["limit"], default: 20, max: 100)
        let kind = try Self.kind(arguments["kind"])
        let names = bowlNames()
        var bowlKey: String?
        if let bowl = arguments["bowl"]?.stringValue, !bowl.trimmingCharacters(in: .whitespaces).isEmpty {
            bowlKey = Projects.key(try resolveBowl(bowl))
        }
        let inboxOnly = arguments["inbox"]?.boolValue ?? false
        if inboxOnly, bowlKey != nil { throw Failure(message: "Give either bowl or inbox, not both.") }
        let tag = arguments["tag"]?.stringValue.map(Note.cleanTag).flatMap { $0.isEmpty ? nil : $0.lowercased() }
        var documentKind: DocumentKind?
        if let raw = arguments["document_kind"]?.stringValue, !raw.isEmpty {
            guard let named = DocumentKind.named(raw) else {
                throw Failure(message: "Unknown document_kind \"\(raw)\". Known: \(DocumentKind.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            documentKind = named
        }
        let from = try Self.day(arguments["from"], name: "from")
        let to = try Self.day(arguments["to"], name: "to").flatMap { Calendar.current.date(byAdding: .day, value: 1, to: $0) }

        let all = livingNotes()
        var documents: [UUID: ChatDocument] = [:]
        var candidates: [Note] = []
        for note in all {
            let document = ChatDocument(note: note)
            if let kind, document.kind != kind { continue }
            if let bowlKey, !note.projectIDs.contains(bowlKey) { continue }
            if inboxOnly, !note.isInInbox { continue }
            if let tag, !document.tags.contains(where: { $0.lowercased() == tag }) { continue }
            if let documentKind {
                guard let raw = document.documentKind, DocumentKind(rawValue: raw) == documentKind else { continue }
            }
            if let from, document.date < from { continue }
            if let to, document.date >= to { continue }
            documents[note.id] = document
            candidates.append(note)
        }

        var ordered: [(note: Note, match: String?)] = []
        if query.isEmpty {
            ordered = candidates.sorted { (documents[$0.id]?.date ?? $0.createdAt) > (documents[$1.id]?.date ?? $1.createdAt) }.map { ($0, nil) }
        } else {
            let ids = Set(candidates.map(\.id))
            let chunks = await passages(all).filter { ids.contains($0.noteID) }
            let vector = await queryVector(query)
            let ranked = ChatRetrieval.search(query, in: chunks, queryVector: vector, budget: 5_000_000, limit: 1_000)
            let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var seen = Set<UUID>()
            for chunk in ranked where seen.insert(chunk.noteID).inserted {
                if let note = byID[chunk.noteID] { ordered.append((note, chunk.text)) }
            }
            // Words the ranking leaves out (only common words) or notes not in the index yet: plain text search.
            let rest = candidates.filter { !seen.contains($0.id) && $0.matches(query) }.sorted { $0.createdAt > $1.createdAt }
            ordered += rest.map { ($0, nil) }
        }

        let results: [JSONValue] = ordered.prefix(limit).map { item in
            var entry = summary(item.note, document: documents[item.note.id], names: names)
            if let match = item.match, case .object(var object) = entry {
                object["match"] = .string(Self.cut(match, 400))
                entry = .object(object)
            }
            return entry
        }
        return .json(["total": .int(ordered.count), "returned": .int(results.count), "results": .array(results)])
    }

    private func getEntry(_ arguments: [String: JSONValue]) throws -> MCPToolResult {
        let note = try entry(arguments["id"])
        let maxLength = max(500, arguments["max_length"]?.intValue ?? Self.defaultMaxLength)
        let names = bowlNames()
        let document = ChatDocument(note: note)
        guard case .object(var object) = summary(note, document: document, names: names) else { return .failure("Internal error") }
        object.removeValue(forKey: "snippet")
        var truncated: [JSONValue] = []
        func long(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            object[key] = .string(Self.cut(value, maxLength))
            if value.count > maxLength { truncated.append(.string(key)) }
        }
        long("text", note.text)
        long("summary", note.summary)
        if !note.segments.isEmpty { long("transcript", note.transcriptText()) }
        long("page_text", note.pageText)
        if note.isRecording, note.duration > 0 { object["duration_seconds"] = .int(Int(note.duration.rounded())) }
        if note.isRecording, !note.speakers.isEmpty { object["speakers"] = .array(note.speakers.map { .string($0.name) }) }
        let attachments = note.attachments
        if !attachments.isEmpty {
            object["files"] = .array(attachments.map { file in
                var item: [String: JSONValue] = ["name": .string(file.name), "kind": .string(file.kind.rawValue)]
                if file.bytes > 0 { item["bytes"] = .int(Int(file.bytes)) }
                return .object(item)
            })
        }
        if note.isTodo {
            var todo = object["todo"]?.objectValue ?? [:]
            let subtasks = Todos.subtasks(in: note.text)
            if !subtasks.isEmpty {
                todo["subtasks"] = .array(subtasks.map { ["text": .string($0.text), "done": .bool($0.done)] })
            }
            if let doneAt = note.todoDoneAt, note.isDone { todo["done_at"] = .string(Self.timestamp(doneAt)) }
            object["todo"] = .object(todo)
        }
        if note.status != .ready { object["status"] = .string(note.status.rawValue) }
        if !truncated.isEmpty { object["truncated"] = .array(truncated) }
        return .json(.object(object))
    }

    private func listBowls(_ arguments: [String: JSONValue]) -> MCPToolResult {
        let includeArchived = arguments["include_archived"]?.boolValue ?? false
        var counts: [String: Int] = [:]
        var inbox = 0
        for note in livingNotes() {
            if note.projectIDs.isEmpty { inbox += 1 }
            for id in Set(note.projectIDs) { counts[id, default: 0] += 1 }
        }
        let list = bowls().filter { includeArchived || !$0.isArchived }.sorted { a, b in
            a.isPinned != b.isPinned ? a.isPinned : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        let bowls: [JSONValue] = list.map { bowl in
            var item: [String: JSONValue] = [
                "id": .string(Projects.key(bowl)),
                "name": .string(bowl.name),
                "entries": .int(counts[Projects.key(bowl)] ?? 0),
                "created": .string(Self.timestamp(bowl.createdAt)),
            ]
            if bowl.isPinned { item["pinned"] = true }
            if bowl.isArchived { item["archived"] = true }
            if bowl.shareCopyToken != nil { item["shared_with_me"] = true }
            return .object(item)
        }
        return .json(["bowls": .array(bowls), "inbox_entries": .int(inbox)])
    }

    private func listInbox(_ arguments: [String: JSONValue]) throws -> MCPToolResult {
        let limit = try Self.limit(arguments["limit"], default: 50, max: 200)
        let notes = Inbox.notes(livingNotes())
        let names = bowlNames()
        let entries = notes.prefix(limit).map { summary($0, document: nil, names: names) }
        return .json(["total": .int(notes.count), "returned": .int(entries.count), "entries": .array(entries)])
    }

    private func recentEntries(_ arguments: [String: JSONValue]) throws -> MCPToolResult {
        let limit = try Self.limit(arguments["limit"], default: 20, max: 100)
        let kind = try Self.kind(arguments["kind"])
        let byUpdate: Bool
        switch arguments["order"]?.stringValue ?? "created" {
        case "created": byUpdate = false
        case "updated": byUpdate = true
        case let other: throw Failure(message: "Unknown order \"\(other)\": use created or updated.")
        }
        var notes = livingNotes()
        if let days = arguments["days"]?.intValue {
            guard days > 0 else { throw Failure(message: "days must be at least 1.") }
            let since = now().addingTimeInterval(-Double(days) * 86_400)
            notes = notes.filter { (byUpdate ? $0.updatedAt : $0.createdAt) >= since }
        }
        var documents: [UUID: ChatDocument] = [:]
        if let kind {
            notes = notes.filter { note in
                let document = ChatDocument(note: note)
                documents[note.id] = document
                return document.kind == kind
            }
        }
        notes.sort { byUpdate ? $0.updatedAt > $1.updatedAt : $0.createdAt > $1.createdAt }
        let names = bowlNames()
        let entries = notes.prefix(limit).map { summary($0, document: documents[$0.id], names: names) }
        return .json(["total": .int(notes.count), "returned": .int(entries.count), "entries": .array(entries)])
    }

    // MARK: Changing

    private func createNote(_ arguments: [String: JSONValue]) throws -> MCPToolResult {
        let text = arguments["text"]?.stringValue ?? ""
        let title = (arguments["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !title.isEmpty else {
            throw Failure(message: "The note needs a text or a title.")
        }
        guard text.count <= 1_000_000, title.count <= 500 else { throw Failure(message: "The note is too long.") }
        var bowl: NoteFolder?
        if let name = arguments["bowl"]?.stringValue, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            bowl = try resolveBowl(name)
            if bowl?.isArchived == true { throw Failure(message: "The bowl \"\(bowl!.name)\" is archived.") }
            if let bowl, BowlSharing.shared.isReadOnly(bowl.id) { throw Failure(message: "The bowl \"\(bowl.name)\" is shared with you to view only.") }
        }
        let note = Note()
        note.source = .note
        note.title = title
        note.titleIsCustom = !title.isEmpty
        note.text = text
        note.createdAt = now()
        note.updatedAt = note.createdAt
        context.insert(note)
        if let bowl {
            Inbox.file(note, into: Projects.key(bowl), in: context)
        } else {
            try? context.save()
        }
        return .json(["created": true, "entry": summary(note, document: nil, names: bowlNames())])
    }

    private func moveToBowl(_ arguments: [String: JSONValue]) throws -> MCPToolResult {
        let note = try entry(arguments["id"])
        let toInbox = arguments["to_inbox"]?.boolValue ?? false
        let name = arguments["bowl"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
        if toInbox == !name.isEmpty { throw Failure(message: "Give either bowl or to_inbox: true.") }
        if BowlSharing.shared.isReadOnly(note) { throw Failure(message: "The entry is in a bowl shared with you to view only.") }
        if toInbox {
            if !note.projectIDs.isEmpty {
                note.projectIDs = []
                note.updatedAt = now()
                try? context.save()
            }
        } else {
            let bowl = try resolveBowl(name)
            if bowl.isArchived { throw Failure(message: "The bowl \"\(bowl.name)\" is archived.") }
            if BowlSharing.shared.isReadOnly(bowl.id) { throw Failure(message: "The bowl \"\(bowl.name)\" is shared with you to view only.") }
            if note.projectIDs != [Projects.key(bowl)] { Inbox.file(note, into: Projects.key(bowl), in: context) }
        }
        return .json(["moved": true, "entry": summary(note, document: nil, names: bowlNames())])
    }

    // MARK: Helpers

    private func entry(_ value: JSONValue?) throws -> Note {
        guard let raw = value?.stringValue?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { throw Failure(message: "id is missing.") }
        guard let id = UUID(uuidString: raw) else { throw Failure(message: "\"\(raw)\" is not an entry id (a UUID).") }
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let note = try? context.fetch(descriptor).first, !note.isDeleted else {
            throw Failure(message: "No entry with the id \(raw).")
        }
        return note
    }

    /// A bowl by its id or its name (case does not matter). Two bowls of the same name have to be named by id.
    func resolveBowl(_ reference: String) throws -> NoteFolder {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = bowls()
        if let id = UUID(uuidString: reference), let bowl = all.first(where: { $0.id == id }) { return bowl }
        let named = all.filter { $0.name.compare(reference, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if named.count == 1 { return named[0] }
        if named.count > 1 {
            throw Failure(message: "Several bowls are called \"\(reference)\": use the id (\(named.map { Projects.key($0) }.joined(separator: ", "))).")
        }
        throw Failure(message: "No bowl \"\(reference)\". list_bowls shows them.")
    }

    /// The short form of an entry, as the lists and the search give it.
    func summary(_ note: Note, document: ChatDocument?, names: [String: String]) -> JSONValue {
        let document = document ?? ChatDocument(note: note)
        var object: [String: JSONValue] = [
            "id": .string(note.id.uuidString),
            "title": .string(note.displayTitle),
            "kind": .string(document.kind.rawValue),
            "created": .string(Self.timestamp(note.createdAt)),
            "updated": .string(Self.timestamp(note.updatedAt)),
            "tags": .array(document.tags.map(JSONValue.string)),
        ]
        if let key = note.projectIDs.first {
            object["bowl"] = ["id": .string(key), "name": .optional(names[key])]
        } else {
            object["bowl"] = .null
            object["in_inbox"] = true
        }
        if !document.snippet.isEmpty { object["snippet"] = .string(document.snippet) }
        if let url = note.url { object["url"] = .string(url) }
        if let state = document.todoState {
            var todo: [String: JSONValue] = ["state": .string(state)]
            if let due = document.dueDay { todo["due"] = .string(due) }
            if document.subtasksTotal > 0 { todo["subtasks_done"] = .int(document.subtasksDone); todo["subtasks_total"] = .int(document.subtasksTotal) }
            if note.isOverdue { todo["overdue"] = true }
            object["todo"] = .object(todo)
        }
        if let info = document.documentInfo {
            var paper: [String: JSONValue] = ["kind": .string((info.kind ?? .other).rawValue)]
            if let day = info.day { paper["date"] = .string(day) }
            if let correspondent = info.correspondent { paper["from"] = .string(correspondent) }
            if let amount = info.amount { paper["amount"] = .string(amount) }
            object["document"] = .object(paper)
        }
        return .object(object)
    }

    static func timestamp(_ date: Date) -> String {
        date.ISO8601Format()
    }

    static func cut(_ text: String, _ length: Int) -> String {
        text.count > length ? String(text.prefix(length)) + "…" : text
    }

    static func limit(_ value: JSONValue?, default fallback: Int, max: Int) throws -> Int {
        guard let value, !value.isNull else { return fallback }
        guard let number = value.intValue, number >= 1 else { throw Failure(message: "limit must be a whole number of at least 1.") }
        return min(number, max)
    }

    static func kind(_ value: JSONValue?) throws -> ChatDocument.Kind? {
        guard let raw = value?.stringValue, !raw.isEmpty else { return nil }
        guard let kind = ChatDocument.Kind(rawValue: raw.lowercased()) else {
            throw Failure(message: "Unknown kind \"\(raw)\". Known: \(kinds.joined(separator: ", ")).")
        }
        return kind
    }

    /// A day "yyyy-MM-dd" as the start of that day here.
    static func day(_ value: JSONValue?, name: String) throws -> Date? {
        guard let raw = value?.stringValue?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let parts = raw.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            throw Failure(message: "\(name) must be a day like 2026-11-22.")
        }
        return date
    }
}
