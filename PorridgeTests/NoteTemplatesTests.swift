import SwiftData
import XCTest
@testable import Porridge

/// Note templates: placeholders, entries made from a template (bowl, subtasks, due day, repeat rule), the file
/// they are kept in and how two copies merge.
@MainActor
final class NoteTemplatesTests: XCTestCase {
    private var root: URL!
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    /// Monday, 16 November 2026, 09:05 in Berlin.
    private var monday: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 9, minute: 5))!
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NoteTemplatesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func values(title: String = "") -> NoteTemplates.Values {
        NoteTemplates.Values(now: monday, title: title, calendar: calendar, locale: Locale(identifier: "en_US"))
    }

    // MARK: Placeholders

    func testPlaceholdersAreFilled() {
        let text = "{{weekday}}, {{date:yyyy-MM-dd}} at {{time:HH:mm}}: {{title}}"
        XCTAssertEqual(NoteTemplates.expand(text, with: values(title: "Kickoff")), "Monday, 2026-11-16 at 09:05: Kickoff")
        XCTAssertEqual(NoteTemplates.expand("{{date}}", with: values()), "Nov 16, 2026")
        XCTAssertFalse(NoteTemplates.expand("{{time}}", with: values()).contains("{{"))
    }

    func testPlaceholdersIgnoreCaseAndSpacesAndKeepUnknownOnes() {
        XCTAssertEqual(NoteTemplates.expand("{{ Weekday }} {{nope}} {{", with: values()), "Monday {{nope}} {{")
        XCTAssertEqual(NoteTemplates.expand("No placeholders", with: values()), "No placeholders")
    }

    func testCursorIsRemovedOrKept() {
        XCTAssertEqual(NoteTemplates.expand("a{{cursor}}b", with: values()), "ab")
        XCTAssertEqual(NoteTemplates.expand("a{{cursor}}b", with: values(), keepingCursor: true), "a\(NoteTemplates.cursorMarker)b")
        let template = NoteTemplate(name: "T", body: "## Notes\n- {{cursor}}\n- {{cursor}}")
        let (text, cursor) = NoteTemplates.insertion(of: template, values: values())
        XCTAssertEqual(text, "## Notes\n- \n- ")
        XCTAssertEqual(cursor, 11, "the first {{cursor}} counts")
    }

    func testNeedsTitleOnlyWhenTitleIsUsed() {
        XCTAssertTrue(NoteTemplate(name: "A", title: "{{title}} · {{date}}").needsTitle)
        XCTAssertTrue(NoteTemplate(name: "B", body: "About {{ TITLE }}").needsTitle)
        XCTAssertFalse(NoteTemplate(name: "C", title: "{{date}}", body: "Text").needsTitle)
        XCTAssertFalse(NoteTemplate(name: "D", kind: .note, subtasks: ["{{title}}"]).needsTitle, "a note has no subtasks")
        XCTAssertTrue(NoteTemplate(name: "E", kind: .todo, subtasks: ["Call {{title}}"]).needsTitle)
    }

    // MARK: Making entries

    func testNoteFromTemplate() throws {
        let context = try TestStore.context()
        let template = NoteTemplate(name: "Meeting", title: "{{title}} · {{date:d MMM}}", body: "## Attendees\n- {{cursor}}\n\n| A | B |\n|---|---|\n| 1 | 2 |")
        let note = NoteTemplates.create(from: template, title: " Kickoff ", in: context, now: monday, calendar: calendar)
        XCTAssertEqual(note.title, "Kickoff · 16 Nov")
        XCTAssertTrue(note.titleIsCustom)
        XCTAssertEqual(note.text, "## Attendees\n- \n\n| A | B |\n|---|---|\n| 1 | 2 |")
        XCTAssertFalse(note.isTodo)
        XCTAssertTrue(note.isInInbox)
        XCTAssertEqual(note.source, .note)
        XCTAssertNotNil(note.modelContext, "the entry is saved")
    }

    func testTodoWithSubtasksDueDayAndRepeat() throws {
        let context = try TestStore.context()
        let template = NoteTemplate(
            name: "Packing", kind: .todo, title: "Pack for {{title}}", body: "Before {{weekday}}",
            subtasks: ["Passport", "Charger for {{title}}"], dueOffset: 7, repeatRule: TodoRepeat.monthly.raw
        )
        let todo = NoteTemplates.create(from: template, title: "Rome", in: context, now: monday, calendar: calendar)
        XCTAssertTrue(todo.isTodo)
        XCTAssertFalse(todo.isDone)
        XCTAssertEqual(todo.title, "Pack for Rome")
        XCTAssertEqual(todo.text, "Before Monday\n- [ ] Passport\n- [ ] Charger for Rome")
        XCTAssertEqual(Todos.subtasks(in: todo.text).map(\.text), ["Passport", "Charger for Rome"])
        XCTAssertEqual(todo.todoDueDay, "2026-11-23")
        XCTAssertEqual(todo.todoRepeat, TodoRepeat(unit: .month, interval: 1, anchorDay: 23), "anchored to the due day")
    }

    func testRepeatingTodoWithoutOffsetIsDueToday() throws {
        let context = try TestStore.context()
        let template = NoteTemplate(name: "Weekly", kind: .todo, title: "Review", repeatRule: TodoRepeat.weekly.raw)
        let todo = NoteTemplates.create(from: template, in: context, now: monday, calendar: calendar)
        XCTAssertEqual(todo.todoDueDay, "2026-11-16")
        XCTAssertEqual(todo.todoRepeat?.unit, .week)
        let plain = NoteTemplates.create(from: NoteTemplate(name: "P", kind: .todo, title: "Plain"), in: context, now: monday, calendar: calendar)
        XCTAssertNil(plain.todoDueDay)
        XCTAssertNil(plain.todoRepeat)
    }

    func testNoteTemplateIgnoresTodoFields() throws {
        let context = try TestStore.context()
        let template = NoteTemplate(name: "N", kind: .note, title: "N", subtasks: ["x"], dueOffset: 1, repeatRule: TodoRepeat.daily.raw)
        let note = NoteTemplates.create(from: template, in: context, now: monday, calendar: calendar)
        XCTAssertFalse(note.isTodo)
        XCTAssertEqual(note.text, "")
        XCTAssertNil(note.todoDueDay)
    }

    func testBowlOfTheTemplateOrTheOpenOneOrInbox() throws {
        let context = try TestStore.context()
        let work = NoteFolder(name: "Work")
        let home = NoteFolder(name: "Home")
        let old = NoteFolder(name: "Old")
        old.archivedAt = monday
        [work, home, old].forEach(context.insert)
        try context.save()
        let workKey = Projects.key(work), homeKey = Projects.key(home)

        let inWork = NoteTemplates.create(from: NoteTemplate(name: "W", title: "W", bowl: workKey), fallbackBowl: homeKey, in: context, now: monday)
        XCTAssertEqual(inWork.projectIDs, [workKey], "the template's bowl comes first")
        XCTAssertNotNil(inWork.filedAt)

        let inOpen = NoteTemplates.create(from: NoteTemplate(name: "O", title: "O"), fallbackBowl: homeKey, in: context, now: monday)
        XCTAssertEqual(inOpen.projectIDs, [homeKey], "without a bowl of its own: the bowl that is open")

        let gone = NoteTemplates.create(from: NoteTemplate(name: "G", title: "G", bowl: UUID().uuidString), fallbackBowl: homeKey, in: context, now: monday)
        XCTAssertTrue(gone.isInInbox, "a deleted bowl: the Inbox")

        let archived = NoteTemplates.create(from: NoteTemplate(name: "A", title: "A", bowl: Projects.key(old)), in: context, now: monday)
        XCTAssertTrue(archived.isInInbox, "an archived bowl: the Inbox")
    }

    func testViewOnlyBowlFallsBackToInbox() throws {
        let context = try TestStore.context()
        let shared = NoteFolder(name: "Shared")
        context.insert(shared)
        try context.save()
        let key = Projects.key(shared)
        let viewOnly: (String) -> Bool = { $0 == key }

        let fromTemplate = NoteTemplates.create(from: NoteTemplate(name: "S", title: "S", bowl: key), in: context, now: monday, isReadOnly: viewOnly)
        XCTAssertTrue(fromTemplate.isInInbox)
        let fromOpen = NoteTemplates.create(from: NoteTemplate(name: "S", title: "S"), fallbackBowl: key, in: context, now: monday, isReadOnly: viewOnly)
        XCTAssertTrue(fromOpen.isInInbox)
    }

    // MARK: From an entry

    func testDraftFromTodo() {
        let todo = Note()
        todo.title = "Trip"
        todo.titleIsCustom = true
        todo.text = "Bring\n- [x] Passport\n- [ ] Charger\n![Photo](attachment:abc.jpg)"
        todo.todoState = .open
        todo.todoDueDay = "2026-11-20"
        todo.todoRepeat = TodoRepeat(unit: .month, interval: 1, anchorDay: 20)
        todo.projectIDs = ["BOWL"]
        let template = NoteTemplates.draft(from: todo)
        XCTAssertEqual(template.name, "Trip")
        XCTAssertEqual(template.kind, .todo)
        XCTAssertEqual(template.title, "Trip")
        XCTAssertEqual(template.body, "Bring\n- [ ] Passport\n- [ ] Charger", "unticked, without the images of the entry")
        XCTAssertEqual(template.bowl, "BOWL")
        XCTAssertEqual(template.repeatRule, "month:1")
    }

    func testDuplicateHasNewIdAndName() {
        let template = NoteTemplate(name: "Weekly", body: "x")
        let copy = NoteTemplates.duplicate(template)
        XCTAssertNotEqual(copy.id, template.id)
        XCTAssertEqual(copy.name, "Weekly Copy")
        XCTAssertEqual(copy.body, "x")
    }

    // MARK: The file

    func testStoreKeepsTemplatesAcrossLaunches() async throws {
        let local = root.appendingPathComponent("note-templates.json")
        let store = NoteTemplateStore(localURL: local, cloudFolder: { nil })
        await store.flush()
        let added = store.add(NoteTemplate(name: "  Packing  ", kind: .todo, subtasks: ["Passport"], dueOffset: 1, repeatRule: "week:1"))
        XCTAssertEqual(added.name, "Packing")
        store.add(NoteTemplate(name: "Agenda", body: "# {{title}}"))
        await store.flush()
        XCTAssertEqual(store.templates.map(\.name), ["Agenda", "Packing"], "by name")

        let again = NoteTemplateStore(localURL: local, cloudFolder: { nil })
        await again.flush()
        XCTAssertEqual(again.templates, store.templates, "a round trip keeps every field")
        XCTAssertEqual(again.template(added.id)?.subtasks, ["Passport"])
        XCTAssertEqual(again.template(added.id)?.repeatRule, "week:1")
    }

    func testRenameUpdateDeleteAndUndo() async throws {
        let store = NoteTemplateStore(localURL: root.appendingPathComponent("t.json"), cloudFolder: { nil })
        await store.flush()
        let template = store.add(NoteTemplate(name: "A"))
        store.rename(template.id, to: "B")
        XCTAssertEqual(store.template(template.id)?.name, "B")
        var changed = store.template(template.id)!
        changed.body = "new"
        store.update(changed)
        XCTAssertEqual(store.template(template.id)?.body, "new")
        let copy = store.duplicate(template.id)
        XCTAssertEqual(store.templates.count, 2)
        XCTAssertEqual(copy?.body, "new")

        let gone = try XCTUnwrap(store.delete(template.id))
        XCTAssertNil(store.template(template.id))
        store.add(gone)
        XCTAssertEqual(store.template(template.id)?.name, "B", "Undo puts it back")
        await store.flush()
        let again = NoteTemplateStore(localURL: root.appendingPathComponent("t.json"), cloudFolder: { nil })
        await again.flush()
        XCTAssertNotNil(again.template(template.id), "put back after its deletion: kept by the merge")
    }

    func testMergeTakesTheNewerAndRemembersDeletions() {
        let early = Date(timeIntervalSince1970: 1_790_000_000)
        let later = early.addingTimeInterval(60)
        let id = UUID()
        let a = NoteTemplate(id: id, name: "Old", createdAt: early)
        var b = a
        b.name = "New"
        b.updatedAt = later
        let other = NoteTemplate(name: "Other", createdAt: early)
        let merged = NoteTemplateFile.merged(NoteTemplateFile(templates: [a, other]), NoteTemplateFile(templates: [b]), now: later)
        XCTAssertEqual(merged.templates.map(\.name), ["New", "Other"])
        XCTAssertEqual(NoteTemplateFile.merged(NoteTemplateFile(templates: [b]), NoteTemplateFile(templates: [a, other]), now: later), merged, "order does not matter")

        let deleted = NoteTemplateFile(deleted: [id.uuidString: later.addingTimeInterval(1)])
        XCTAssertEqual(NoteTemplateFile.merged(merged, deleted, now: later).templates.map(\.name), ["Other"], "a newer deletion removes it")
        let stale = NoteTemplateFile(deleted: [id.uuidString: early])
        XCTAssertEqual(NoteTemplateFile.merged(merged, stale, now: later).templates.map(\.name), ["New", "Other"], "an older deletion does not")
    }

    func testTwoDevicesShareThroughICloud() async throws {
        let cloud = root.appendingPathComponent("cloud", isDirectory: true)
        let phone = NoteTemplateStore(localURL: root.appendingPathComponent("phone/t.json"), cloudFolder: { cloud })
        let mac = NoteTemplateStore(localURL: root.appendingPathComponent("mac/t.json"), cloudFolder: { cloud })
        await phone.flush()
        await mac.flush()
        let made = phone.add(NoteTemplate(name: "Agenda"))
        await phone.flush()
        await mac.reload()
        XCTAssertEqual(mac.templates.map(\.name), ["Agenda"])

        mac.delete(made.id)
        mac.add(NoteTemplate(name: "Packing", kind: .todo))
        await mac.flush()
        await phone.reload()
        XCTAssertEqual(phone.templates.map(\.name), ["Packing"], "the deletion and the new one came over")
    }

    func testUnknownFieldsAndBrokenTemplatesRead() throws {
        let json = """
        {"version": 2, "future": true, "templates": [
          {"id": "\(UUID().uuidString)", "name": "Good", "kind": "todo", "createdAt": "2026-11-01T10:00:00.000Z", "color": "red"},
          {"name": "No id"}
        ], "deleted": {}}
        """
        let url = root.appendingPathComponent("t.json")
        try Data(json.utf8).write(to: url)
        let file = try XCTUnwrap(NoteTemplateStore.read(url))
        XCTAssertEqual(file.templates.map(\.name), ["Good"])
        XCTAssertEqual(file.templates.first?.kind, .todo)
        XCTAssertEqual(file.templates.first?.subtasks, [])
        XCTAssertNil(file.templates.first?.dueOffset)
    }

    // MARK: Examples

    func testExamplesOnlyForSomeoneWithoutTemplates() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NoteTemplatesTests-\(UUID().uuidString)"))
        let empty = NoteTemplateStore(localURL: root.appendingPathComponent("a.json"), cloudFolder: { nil }, examplesKey: "examples", defaults: defaults)
        await empty.flush()
        XCTAssertEqual(empty.templates.count, 2)
        XCTAssertEqual(Set(empty.templates.map(\.id)), Set(NoteTemplates.examples.map(\.id)))
        // Deleted, they do not come back.
        empty.templates.forEach { empty.delete($0.id) }
        await empty.reload()
        XCTAssertTrue(empty.templates.isEmpty)

        // Someone with templates of their own gets none.
        let own = root.appendingPathComponent("b.json")
        NoteTemplateStore.write(NoteTemplateFile(templates: [NoteTemplate(name: "Mine")]), to: own)
        let other = try XCTUnwrap(UserDefaults(suiteName: "NoteTemplatesTests-\(UUID().uuidString)"))
        let store = NoteTemplateStore(localURL: own, cloudFolder: { nil }, examplesKey: "examples", defaults: other)
        await store.flush()
        XCTAssertEqual(store.templates.map(\.name), ["Mine"])
    }

    func testExamplesExpand() throws {
        let context = try TestStore.context()
        for example in NoteTemplates.examples {
            XCTAssertTrue(example.needsTitle)
            let note = NoteTemplates.create(from: example, title: "Berlin", in: context, now: monday, calendar: calendar)
            XCTAssertFalse(note.title.contains("{{"))
            XCTAssertFalse(note.text.contains("{{"))
        }
    }
}
