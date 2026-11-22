import Foundation
import SwiftData

/// A note template: a ready-made start for a note or a to-do (headings, checklists, tables, whatever the editor
/// writes as Markdown). Not the summary templates of meetings (`SummaryTemplate`): those tell the summary what to
/// look at; these make new entries.
///
/// Kept in one JSON file (`NoteTemplateStore`), not in the database: the synced store gets no new fields.
struct NoteTemplate: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case note, todo

        var title: String {
            switch self {
            case .note: String(localized: "Note")
            case .todo: String(localized: "To-do")
            }
        }

        var symbol: String { self == .todo ? "checklist" : "text.alignleft" }
    }

    var id: UUID
    var name: String
    var kind: Kind
    /// The title of the new entry, with placeholders ("Meeting · {{date}}"); empty = no title of its own.
    var title: String
    /// The text of the new entry, Markdown with placeholders.
    var body: String
    /// The bowl (`NoteFolder.id` as uppercase string) the new entry goes into; nil = the Inbox (or the bowl open).
    var bowl: String?
    /// To-dos: subtasks added under the text as checklist lines.
    var subtasks: [String]
    /// To-dos: due this many days after the day it is made (0 = today); nil = no due day.
    var dueOffset: Int?
    /// To-dos: the repeat rule (`TodoRepeat.raw`, without anchor); nil = does not repeat.
    var repeatRule: String?
    var createdAt: Date
    /// The last change; the newer of two copies wins (`NoteTemplateFile.merged`).
    var updatedAt: Date

    init(
        id: UUID = UUID(), name: String, kind: Kind = .note, title: String = "", body: String = "", bowl: String? = nil,
        subtasks: [String] = [], dueOffset: Int? = nil, repeatRule: String? = nil, createdAt: Date = Date(), updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.title = title
        self.body = body
        self.bowl = bowl
        self.subtasks = subtasks
        self.dueOffset = dueOffset
        self.repeatRule = repeatRule
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, title, body, bowl, subtasks, dueOffset, repeatRule, createdAt, updatedAt
    }

    /// Fields a later version adds or this one does not know are read with their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .note
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        bowl = try c.decodeIfPresent(String.self, forKey: .bowl)
        subtasks = (try? c.decodeIfPresent([String].self, forKey: .subtasks)) ?? []
        dueOffset = try? c.decodeIfPresent(Int.self, forKey: .dueOffset)
        repeatRule = try? c.decodeIfPresent(String.self, forKey: .repeatRule)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    var isTodo: Bool { kind == .todo }

    var repeats: TodoRepeat? { isTodo ? repeatRule.flatMap(TodoRepeat.init(raw:)) : nil }

    /// Asks for a title when it is used: `{{title}}` somewhere in it.
    var needsTitle: Bool {
        ([title, body] + (isTodo ? subtasks : [])).contains { NoteTemplates.usesTitle($0) }
    }
}

/// What the templates' file holds: the templates, and when deleted ones went (so a device that still has one does
/// not bring it back).
struct NoteTemplateFile: Codable, Equatable, Sendable {
    var version = 1
    var templates: [NoteTemplate] = []
    /// Deleted templates by id (uppercase UUID string) with the time they went.
    var deleted: [String: Date] = [:]

    init(templates: [NoteTemplate] = [], deleted: [String: Date] = [:]) {
        self.templates = templates
        self.deleted = deleted
    }

    private enum CodingKeys: String, CodingKey { case version, templates, deleted }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        // One template that does not read does not take the others with it.
        templates = (try? c.decodeIfPresent([Lenient<NoteTemplate>].self, forKey: .templates))?.compactMap(\.value) ?? []
        deleted = (try? c.decodeIfPresent([String: Date].self, forKey: .deleted)) ?? [:]
    }

    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    /// Deletions are remembered this long, as for smart filters.
    static let tombstoneLifetime: TimeInterval = SmartFilterFile.tombstoneLifetime

    /// Two copies made one: each template in its newest form, a deletion newer than a template's last change removes it.
    static func merged(_ a: NoteTemplateFile, _ b: NoteTemplateFile, now: Date = Date()) -> NoteTemplateFile {
        var deleted = a.deleted
        for (id, date) in b.deleted { deleted[id] = max(deleted[id] ?? date, date) }
        deleted = deleted.filter { now.timeIntervalSince($0.value) < tombstoneLifetime }
        var byID: [UUID: NoteTemplate] = [:]
        for template in a.templates + b.templates {
            if let known = byID[template.id] {
                // The newer wins; at the same moment one fixed choice, so every device keeps the same.
                if known.updatedAt > template.updatedAt { continue }
                if known.updatedAt == template.updatedAt, String(describing: known) >= String(describing: template) { continue }
            }
            byID[template.id] = template
        }
        let kept = byID.values.filter { template in
            guard let gone = deleted[template.id.uuidString] else { return true }
            return template.updatedAt > gone
        }
        return NoteTemplateFile(templates: NoteTemplates.sorted(Array(kept)), deleted: deleted)
    }
}

enum NoteTemplates {
    /// By name, as the lists show them.
    static func sorted(_ templates: [NoteTemplate]) -> [NoteTemplate] {
        templates.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.createdAt < $1.createdAt : order == .orderedAscending
        }
    }

    // MARK: Placeholders

    /// What the placeholders are filled with.
    struct Values {
        var now: Date = Date()
        /// For `{{title}}`: asked when the entry is made, the note's title when a template is inserted.
        var title: String = ""
        var calendar: Calendar = .current
        var locale: Locale = .current
    }

    /// The placeholders a template may use, for the help text of the editors.
    static let placeholderHelp = "{{date}}, {{time}}, {{weekday}}, {{title}}, {{cursor}}; a format as in {{date:yyyy-MM-dd}}"

    /// `{{ name }}` or `{{ name:format }}`, any case.
    private static let pattern = try! NSRegularExpression(pattern: #"\{\{\s*([A-Za-z]+)\s*(?::([^}]*))?\}\}"#)

    static let cursorMarker = "{{cursor}}"

    static func usesTitle(_ text: String) -> Bool {
        text.contains("{{") && expand(text, with: Values(title: "\u{1}"), keepingCursor: false).contains("\u{1}")
    }

    /// The text with its placeholders filled in: `{{date}}` (the date, medium style), `{{time}}` (short),
    /// `{{weekday}}` ("Monday"), `{{title}}`; `{{date:yyyy-MM-dd}}` and `{{time:HH:mm}}` take a format of their own.
    /// `{{cursor}}` is kept as `cursorMarker` when `keepingCursor`, otherwise removed. Unknown names stay as written.
    static func expand(_ text: String, with values: Values, keepingCursor: Bool = false) -> String {
        guard text.contains("{{") else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            last = match.range.location + match.range.length
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            let format = match.range(at: 2).location == NSNotFound
                ? nil : ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            switch name {
            case "date": result += formatted(values, format: format, date: .medium, time: .none)
            case "time": result += formatted(values, format: format, date: .none, time: .short)
            case "weekday": result += formatted(values, format: format?.isEmpty == false ? format : "EEEE", date: .none, time: .none)
            case "title": result += values.title
            case "cursor": result += keepingCursor ? cursorMarker : ""
            default: result += ns.substring(with: match.range)
            }
        }
        result += ns.substring(from: last)
        return result
    }

    private static func formatted(_ values: Values, format: String?, date: DateFormatter.Style, time: DateFormatter.Style) -> String {
        let formatter = DateFormatter()
        formatter.calendar = values.calendar
        formatter.locale = values.locale
        formatter.timeZone = values.calendar.timeZone
        if let format, !format.isEmpty {
            formatter.dateFormat = format
        } else {
            formatter.dateStyle = date
            formatter.timeStyle = time
        }
        return formatter.string(from: values.now)
    }

    /// The body as it goes into a note at the cursor: placeholders filled, and where `{{cursor}}` was (an offset
    /// in the returned text), if it was there.
    static func insertion(of template: NoteTemplate, values: Values) -> (text: String, cursor: Int?) {
        var text = expand(template.body, with: values, keepingCursor: true)
        if template.isTodo {
            let lines = template.subtasks.map { expand($0, with: values) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !lines.isEmpty {
                text = text.trimmingCharacters(in: .newlines)
                text += (text.isEmpty ? "" : "\n") + lines.map { "- [ ] " + $0 }.joined(separator: "\n")
            }
        }
        guard let range = text.range(of: cursorMarker) else { return (text, nil) }
        let offset = text.distance(from: text.startIndex, to: range.lowerBound)
        text.removeSubrange(range)
        // Only the first one counts.
        text = text.replacingOccurrences(of: cursorMarker, with: "")
        return (text, offset)
    }

    // MARK: Making entries

    /// The text of a new entry: the body, then the subtasks of a to-do as checklist lines.
    static func text(of template: NoteTemplate, values: Values) -> String {
        insertion(of: template, values: values).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The due day of a to-do made now ("yyyy-MM-dd"); a repeating one without an offset starts today.
    static func dueDay(of template: NoteTemplate, now: Date, calendar: Calendar = .current) -> String? {
        guard template.isTodo else { return nil }
        let offset = template.dueOffset ?? (template.repeats != nil ? 0 : nil)
        guard let offset, let today = TodoRepeat.Day(Todos.dueKey(now, calendar: calendar)) else { return nil }
        return today.adding(days: max(0, offset)).key
    }

    /// The bowl a new entry goes into: the template's own while it exists and may be written to; else the bowl the
    /// user is in (`fallback`, already checked by the caller); else the Inbox (nil).
    static func targetBowl(
        of template: NoteTemplate, fallback: String?, existing: Set<String>, isReadOnly: (String) -> Bool
    ) -> String? {
        if let bowl = template.bowl, existing.contains(bowl), !isReadOnly(bowl) { return bowl }
        if template.bowl != nil { return nil }
        if let fallback, !isReadOnly(fallback) { return fallback }
        return nil
    }

    /// A new note or to-do made from the template and saved. `title` fills `{{title}}`; `fallbackBowl` is the bowl
    /// the user is in, taken when the template names none. A bowl that is gone, archived or shared with me to view
    /// only is not used: the entry goes into the Inbox.
    @MainActor
    @discardableResult
    static func create(
        from template: NoteTemplate, title asked: String = "", fallbackBowl: String? = nil, in context: ModelContext,
        now: Date = Date(), calendar: Calendar = .current, isReadOnly: ((String) -> Bool)? = nil
    ) -> Note {
        let readOnly = isReadOnly ?? { BowlSharing.shared.isReadOnly(UUID(uuidString: $0)) }
        let values = Values(now: now, title: asked.trimmingCharacters(in: .whitespacesAndNewlines), calendar: calendar)
        let folders = (try? context.fetch(FetchDescriptor<NoteFolder>())) ?? []
        let existing = Set(folders.filter { !$0.isArchived }.map(Projects.key))
        let note = Note()
        note.source = .note
        note.title = expand(template.title, with: values).trimmingCharacters(in: .whitespacesAndNewlines)
        note.titleIsCustom = !note.title.isEmpty
        note.text = text(of: template, values: values)
        note.createdAt = now
        note.updatedAt = now
        if template.isTodo {
            note.todoState = .open
            note.todoDueDay = dueDay(of: template, now: now, calendar: calendar)
            if let rule = template.repeats { note.todoRepeat = rule.anchored(to: note.todoDueDay) }
        }
        if let bowl = targetBowl(of: template, fallback: fallbackBowl, existing: existing, isReadOnly: readOnly) {
            note.projectIDs = Projects.assigned(bowl)
            note.filedAt = now
        }
        context.insert(note)
        try? context.save()
        return note
    }

    /// A template from an entry ("Save as Template"): its title and text, its bowl; a to-do keeps its repeat rule
    /// and its subtasks unticked. Images (files of that entry) are left out.
    static func draft(from note: Note, now: Date = Date()) -> NoteTemplate {
        var body = note.isTodo ? Todos.setAll(false, in: note.text) : note.text
        body = body.components(separatedBy: "\n").filter { NoteImageRef(line: $0) == nil }.joined(separator: "\n")
        let name = note.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return NoteTemplate(
            name: name.isEmpty ? String(localized: "Template") : name,
            kind: note.isTodo ? .todo : .note,
            title: note.titleIsCustom ? note.title : "",
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            bowl: note.projectIDs.first,
            repeatRule: note.isTodo ? note.todoRepeat.map { TodoRepeat(unit: $0.unit, interval: $0.interval).raw } : nil,
            createdAt: now
        )
    }

    /// A copy of a template under a new name ("Meeting Notes Copy").
    static func duplicate(_ template: NoteTemplate, now: Date = Date()) -> NoteTemplate {
        var copy = template
        copy.id = UUID()
        copy.name = String(localized: "\(template.name) Copy")
        copy.createdAt = now
        copy.updatedAt = now
        return copy
    }

    // MARK: Describing

    /// "To-do · Due Tomorrow · Weekly · Work", for the rows of the lists.
    static func summary(of template: NoteTemplate, bowlName: (String) -> String?) -> String {
        var parts = [template.kind.title]
        if template.isTodo {
            if let offset = template.dueOffset { parts.append(dueTitle(offset)) }
            if let rule = template.repeats { parts.append(rule.title) }
            if !template.subtasks.isEmpty {
                parts.append(template.subtasks.count == 1 ? String(localized: "1 subtask") : String(localized: "\(template.subtasks.count) subtasks"))
            }
        }
        if let bowl = template.bowl { parts.append(bowlName(bowl) ?? String(localized: "Deleted Bowl")) }
        return parts.joined(separator: " · ")
    }

    /// The choices for the due day of a template's to-do.
    static let dueOffsets: [Int?] = [nil, 0, 1, 2, 3, 7, 14, 30]

    static func dueTitle(_ offset: Int?) -> String {
        switch offset {
        case nil: String(localized: "No Due Date")
        case 0?: String(localized: "Due Today")
        case 1?: String(localized: "Due Tomorrow")
        case 7?: String(localized: "Due in 1 Week")
        case 14?: String(localized: "Due in 2 Weeks")
        case let days?: String(localized: "Due in \(days) Days")
        }
    }

    /// The choices for the repeat rule (raw values; nil = does not repeat).
    static let repeatChoices: [String?] = [nil] + TodoRepeat.presets.map(\.raw)

    static func repeatTitle(_ raw: String?) -> String {
        raw.flatMap(TodoRepeat.init(raw:))?.title ?? String(localized: "Never")
    }

    // MARK: Examples

    /// Two examples for someone with no templates yet. Fixed ids and dates: two devices that both add them end up
    /// with the same two, not four.
    static let examples: [NoteTemplate] = {
        let date = Date(timeIntervalSince1970: 1_795_000_000)
        return [
            NoteTemplate(
                id: UUID(uuidString: "5E0B7C1A-7A43-4E0B-9B5B-2B1D6C0A0001")!,
                name: String(localized: "Meeting Notes"),
                kind: .note,
                title: "{{title}} · {{date}}",
                body: """
                ## Attendees
                - {{cursor}}

                ## Agenda
                -

                ## Notes


                ## Next Steps
                - [ ]
                """,
                createdAt: date
            ),
            NoteTemplate(
                id: UUID(uuidString: "5E0B7C1A-7A43-4E0B-9B5B-2B1D6C0A0002")!,
                name: String(localized: "Packing List"),
                kind: .todo,
                title: "Pack for {{title}}",
                subtasks: ["Passport and tickets", "Phone charger", "Toothbrush", "Clothes", "Medication"],
                dueOffset: 1,
                createdAt: date
            ),
        ]
    }()
}
