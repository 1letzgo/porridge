import SwiftData
import XCTest
@testable import Porridge

/// The chat's actions: what the model proposes (tool calls and ACTION lines), how it is checked against the entries
/// the chat showed, how a confirmed change is made, and how it is taken back.
@MainActor
final class ChatActionsTests: XCTestCase {
    private let now = DocumentInfo.date(fromDay: "2026-11-22")!

    private func note(_ title: String, text: String = "", in context: ModelContext) -> Note {
        let note = Note()
        note.title = title
        note.text = text
        note.source = .note
        context.insert(note)
        return note
    }

    private func document(_ title: String, in context: ModelContext) -> Note {
        let note = note(title, in: context)
        note.source = .share
        note.attachments = [Attachment(fileName: "a.pdf", name: "\(title).pdf", kindRaw: "pdf")]
        return note
    }

    private func scope(_ notes: [Note], bowls: [NoteFolder], question: String = "") -> ChatActionScope {
        ChatActionScope(numbered: notes.map(\.id), referenced: Set(notes.map(\.id)), question: question, notes: notes, bowls: bowls, now: now)
    }

    // MARK: Parsing

    func testActionLinesAreReadAndTakenOutOfTheAnswer() {
        let answer = """
        Ich lege die Rechnung in die Bowl Steuern [2].

        ACTION: {"action": "move_to_bowl", "entry": "2", "bowl": "Steuern"}
        - `ACTION: {"action": "set_tags", "entry": 2, "add": ["finanzen", "2026"],}`
        ACTION set_todo entry=1 state=done due="2026-11-30"
        """
        let parsed = ChatActionParser.extract(from: answer)
        XCTAssertEqual(parsed.text, "Ich lege die Rechnung in die Bowl Steuern [2].")
        XCTAssertEqual(parsed.calls.count, 3)
        XCTAssertEqual(parsed.calls[0], ChatActionCall(name: "move_to_bowl", arguments: ["entry": "2", "bowl": "Steuern"]))
        XCTAssertEqual(parsed.calls[1].name, "set_tags")
        XCTAssertEqual(parsed.calls[1].list("add"), ["finanzen", "2026"], "a trailing comma is forgiven")
        XCTAssertEqual(parsed.calls[2], ChatActionCall(name: "set_todo", arguments: ["entry": "1", "state": "done", "due": "2026-11-30"]))
    }

    func testFencedBlocksTypographicQuotesAndAliases() {
        let answer = """
        Done as you asked:
        ```action
        {“action”: “new_bowl”, “name”: “Garten”}
        {"tool": "mark_done", "entry": "[3]"}
        ```
        """
        let parsed = ChatActionParser.extract(from: answer)
        XCTAssertEqual(parsed.text, "Done as you asked:")
        XCTAssertEqual(parsed.calls.map(\.name), ["create_bowl", "set_todo"])
        XCTAssertEqual(parsed.calls[0].value("name"), "Garten", "the bowl's name is an argument, not the action's name")
    }

    func testAnAnswerWithoutActionsStaysAsItIs() {
        let answer = "The actions of the meeting: call Anna.\n\nAction items are listed in [2]."
        let parsed = ChatActionParser.extract(from: answer)
        XCTAssertEqual(parsed.text, answer)
        XCTAssertTrue(parsed.calls.isEmpty)
    }

    func testToolCallsOfEachProvider() {
        let openAI: [String: Any] = ["choices": [["message": ["content": NSNull(), "tool_calls": [
            ["type": "function", "function": ["name": "move_to_bowl", "arguments": #"{"entry":"4","bowl":"Taxes"}"#]],
        ]]]]]
        let anthropic: [String: Any] = ["content": [
            ["type": "text", "text": "I can file it."],
            ["type": "tool_use", "id": "x", "name": "set_todo", "input": ["entry": "1", "state": "done"]],
        ]]
        let google: [String: Any] = ["candidates": [["content": ["parts": [
            ["functionCall": ["name": "set_tags", "args": ["entry": "2", "add": ["home"]]]],
        ]]]]]
        let a = CloudLLM.toolCalls(in: openAI, style: .openAICompatible).compactMap { ChatActionCall(name: $0.name, json: $0.arguments) }
        XCTAssertEqual(a, [ChatActionCall(name: "move_to_bowl", arguments: ["entry": "4", "bowl": "Taxes"])])
        let b = CloudLLM.toolCalls(in: anthropic, style: .anthropic).compactMap { ChatActionCall(name: $0.name, json: $0.arguments) }
        XCTAssertEqual(b, [ChatActionCall(name: "set_todo", arguments: ["entry": "1", "state": "done"])])
        let c = CloudLLM.toolCalls(in: google, style: .google).compactMap { ChatActionCall(name: $0.name, json: $0.arguments) }
        XCTAssertEqual(c, [ChatActionCall(name: "set_tags", arguments: ["entry": "2"], lists: ["add": ["home"]])])
        // The tools as each provider wants them.
        let tools = CloudLLM.toolsBody(ChatActionTools.all, style: .anthropic) as? [[String: Any]]
        XCTAssertEqual(tools?.compactMap { $0["name"] as? String }, ["move_to_bowl", "create_bowl", "set_todo", "set_tags", "set_document_info", "create_note"])
        XCTAssertNotNil((CloudLLM.toolsBody(ChatActionTools.all, style: .google) as? [[String: Any]])?.first?["functionDeclarations"])
    }

    func testThePromptTellsAboutActionsOnlyWhenAsked() {
        let context = ChatContext(items: [ChatContextItem(noteID: UUID(), title: "A", date: now, header: "«A» — Note", text: "a", isListing: false, isOutside: false)])
        let plain = ChatService.prompt(question: "What is A?", history: [], context: context, bucket: nil, now: now)
        XCTAssertFalse(plain.system.contains("ACTION"))
        XCTAssertFalse(plain.system.contains("propose changes"))
        let tools = ChatService.prompt(question: "Move A", history: [], context: context, bucket: nil, actions: .tools, now: now)
        XCTAssertTrue(tools.system.contains("propose changes"))
        XCTAssertFalse(tools.system.contains("ACTION:"))
        let inline = ChatService.prompt(question: "Move A", history: [], context: context, earlier: ["«B» — Note"], bucket: nil, actions: .inline, now: now)
        XCTAssertTrue(inline.system.contains("ACTION: {"))
        XCTAssertTrue(inline.user.contains("Entries named earlier in this chat:\n[2] «B» — Note"), "numbered on after the items")
        XCTAssertTrue(ChatActionTools.asksForChange("Verschieb die Rechnung in Steuern"))
        XCTAssertTrue(ChatActionTools.asksForChange("Mark the Telekom to-do as done"))
        XCTAssertFalse(ChatActionTools.asksForChange("Was haben wir im letzten Meeting beschlossen?"))
    }

    // MARK: Checking

    func testEntriesByNumberTitleAndOnlyThoseTheChatShowed() throws {
        let context = try TestStore.context()
        let shown = note("Telekom Rechnung", in: context)
        let hidden = note("Geheim", in: context)
        let other = note("Einkauf", in: context)
        var s = scope([shown, other], bowls: [])
        s.notes = [shown, hidden, other]
        var calls = [
            ChatActionCall(name: "set_tags", arguments: ["entry": "1", "add": "rechnung"]),
            ChatActionCall(name: "set_tags", arguments: ["entry": "[2] «Einkauf»", "add": "x"]),
            ChatActionCall(name: "set_tags", arguments: ["entry": "telekom rechnung", "add": "y"]),
            ChatActionCall(name: "set_tags", arguments: ["entry": "Geheim", "add": "z"]),
            ChatActionCall(name: "set_tags", arguments: ["entry": "7", "add": "z"]),
        ]
        var result = ChatActionResolver.resolve(calls, in: s)
        XCTAssertEqual(result.actions.map(\.operation.noteID), [shown.id, other.id, shown.id])
        XCTAssertEqual(result.remarks.count, 2, "an entry the chat did not show, and a number it did not give")

        // Named by the user in the question: allowed.
        s.question = "Tag Geheim with z"
        calls = [ChatActionCall(name: "set_tags", arguments: ["entry": "Geheim", "add": "z"])]
        result = ChatActionResolver.resolve(calls, in: s)
        XCTAssertEqual(result.actions.first?.operation.noteID, hidden.id)
    }

    func testAmbiguityIsAskedBack() throws {
        let context = try TestStore.context()
        let first = note("Rechnung", in: context)
        let second = note("Rechnung", in: context)
        let a = NoteFolder(name: "Steuern")
        let b = NoteFolder(name: "steuern")
        let result = ChatActionResolver.resolve([
            ChatActionCall(name: "set_todo", arguments: ["entry": "Rechnung", "state": "open"]),
            ChatActionCall(name: "move_to_bowl", arguments: ["entry": "1", "bowl": "Steuern"]),
        ], in: scope([first, second], bowls: [a, b]))
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertTrue(result.remarks[0].hasPrefix("Which “Rechnung” do you mean"))
        XCTAssertTrue(result.remarks[1].contains("2 bowls named"))
    }

    func testRulesNoTodoFromALinkNoDeletingNoNoOps() throws {
        let context = try TestStore.context()
        let link = note("Article", in: context)
        link.url = "https://example.com"
        let bowl = NoteFolder(name: "Work")
        let filed = note("Plan", in: context)
        filed.projectIDs = [Projects.key(bowl)]
        let result = ChatActionResolver.resolve([
            ChatActionCall(name: "set_todo", arguments: ["entry": "1", "state": "open"]),
            ChatActionCall(name: "delete_note", arguments: ["entry": "1"]),
            ChatActionCall(name: "archive", arguments: ["entry": "2"]),
            ChatActionCall(name: "move_to_bowl", arguments: ["entry": "2", "bowl": "work"]),
            ChatActionCall(name: "create_bowl", arguments: ["name": "WORK"]),
            ChatActionCall(name: "set_document_info", arguments: ["entry": "2", "kind": "invoice"]),
        ], in: scope([link, filed], bowls: [bowl]))
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertEqual(result.remarks, [
            "«Article» is a link: it cannot be a to-do.",
            "The chat cannot delete or archive anything.",
            "«Plan» is already in Bowl “Work”.",
            "Bowl “Work” already exists.",
            "«Plan» is not a document.",
        ])
    }

    func testValuesAreReadAsTheAppKeepsThem() throws {
        XCTAssertEqual(ChatActionResolver.amount("119,00 €"), "119.00 EUR")
        XCTAssertEqual(ChatActionResolver.amount("EUR 1.234,56"), "1234.56 EUR")
        XCTAssertEqual(ChatActionResolver.amount("$10.63"), "10.63 USD")
        XCTAssertEqual(ChatActionResolver.amount("42"), "42.00")
        XCTAssertNil(ChatActionResolver.amount("free"))
        XCTAssertEqual(ChatActionResolver.day("2026-03-02", now: now), "2026-03-02")
        XCTAssertEqual(ChatActionResolver.day("2.3.2026", now: now), "2026-03-02")
        XCTAssertEqual(ChatActionResolver.day("morgen", now: now), "2026-11-23")
        XCTAssertNil(ChatActionResolver.day("31.02.2026", now: now))

        let context = try TestStore.context()
        let paper = document("Scan", in: context)
        let result = ChatActionResolver.resolve([
            ChatActionCall(name: "set_document_info", arguments: ["entry": "1", "kind": "Rechnung", "sender": "Telekom", "date": "02.03.2026", "amount": "119,00 €"]),
        ], in: scope([paper], bowls: []))
        XCTAssertEqual(result.actions.first?.operation, .document(note: paper.id, kind: "invoice", day: "2026-03-02", sender: "Telekom", amount: "119.00 EUR"))
    }

    func testANewBowlIsNamedOnTheCard() throws {
        let context = try TestStore.context()
        let entry = note("Rosen schneiden", in: context)
        let result = ChatActionResolver.resolve([
            ChatActionCall(name: "move_to_bowl", arguments: ["entry": "1", "bowl": "Garten"]),
            ChatActionCall(name: "move_to_bowl", arguments: ["entry": "1", "bowl": "Garten"]),
        ], in: scope([entry], bowls: []))
        XCTAssertEqual(result.actions.count, 1, "the same change twice is one card")
        XCTAssertEqual(result.actions[0].title, "Move to new Bowl “Garten”")
        XCTAssertEqual(result.actions[0].subject, "Rosen schneiden")
    }

    // MARK: Making and taking back

    func testMoveIntoANewBowlAndUndo() throws {
        let context = try TestStore.context()
        let old = Projects.create("Alt", in: context)!
        let entry = note("Rosen", in: context)
        entry.projectIDs = [Projects.key(old)]
        try context.save()
        let action = ChatAction(operation: .move(note: entry.id, bowl: .new("Garten")), title: "", symbol: "")
        let run = ChatActionRunner.run([action], in: context, now: now)
        XCTAssertEqual(run.actions[0].status, .done)
        let garden = try XCTUnwrap(EntryActions.bowls(named: "garten", in: context).first)
        XCTAssertEqual(entry.projectIDs, [Projects.key(garden)], "one bowl at most: the old one is left")

        EntryActions.undo(run.undo, in: context)
        XCTAssertEqual(entry.projectIDs, [Projects.key(old)])
        XCTAssertTrue(EntryActions.bowls(named: "Garten", in: context).isEmpty, "the bowl made for it goes again")
    }

    func testTodoTagsDocumentAndNoteWithUndo() throws {
        let context = try TestStore.context()
        let task = note("Pack", text: "- [ ] Socks\n- [ ] Shirts", in: context)
        task.labels = ["travel"]
        let paper = document("Scan", in: context)
        paper.documentInfo = DocumentInfo(kind: .letter, correspondent: "Bank")
        try context.save()
        let before = EntryActions.Snapshot(task)

        let actions = [
            ChatAction(operation: .todo(note: task.id, done: true, due: "2026-11-30"), title: "", symbol: ""),
            ChatAction(operation: .tags(note: task.id, add: ["urgent"], remove: ["travel"]), title: "", symbol: ""),
            ChatAction(operation: .document(note: paper.id, kind: "invoice", day: nil, sender: "Telekom", amount: "119.00 EUR"), title: "", symbol: ""),
            ChatAction(operation: .createNote(title: "Call Anna", text: "", bowl: nil, todo: true, due: "2026-11-24"), title: "", symbol: ""),
        ]
        let run = ChatActionRunner.run(actions, in: context, now: now)
        XCTAssertEqual(run.actions.map(\.status), [.done, .done, .done, .done])
        XCTAssertTrue(task.isDone)
        XCTAssertEqual(task.todoDue, "2026-11-30")
        XCTAssertEqual(task.text, "- [x] Socks\n- [x] Shirts", "done ticks the subtasks")
        XCTAssertEqual(task.labels, ["urgent"])
        XCTAssertEqual(paper.documentInfo?.kind, .invoice)
        XCTAssertEqual(paper.documentInfo?.correspondent, "Telekom")
        XCTAssertEqual(paper.documentInfo?.amount, "119.00 EUR")
        XCTAssertTrue(paper.documentInfo?.edited == true, "set like an edit by hand: reading never replaces it")
        Documents.apply(DocumentInfo(kind: .letter), to: paper)
        XCTAssertEqual(paper.documentInfo?.kind, .invoice)
        let created = try context.fetch(FetchDescriptor<Note>()).filter { $0.title == "Call Anna" }
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.todoState, .open)
        XCTAssertEqual(created.first?.todoDue, "2026-11-24")

        EntryActions.undo(run.undo, in: context)
        XCTAssertTrue(before.matches(task), "the to-do is as it was")
        XCTAssertEqual(paper.documentInfo?.kind, .letter)
        XCTAssertEqual(paper.documentInfo?.correspondent, "Bank")
        XCTAssertTrue(try context.fetch(FetchDescriptor<Note>()).filter { $0.title == "Call Anna" }.isEmpty)
    }

    func testAChangeThatNoLongerFitsFailsAndTheRestIsMade() throws {
        let context = try TestStore.context()
        let gone = note("Gone", in: context)
        gone.deletedAt = now
        let link = note("Link", in: context)
        link.url = "https://example.com"
        let fine = note("Fine", in: context)
        try context.save()
        let run = ChatActionRunner.run([
            ChatAction(operation: .tags(note: gone.id, add: ["x"], remove: []), title: "", symbol: ""),
            ChatAction(operation: .todo(note: link.id, done: false, due: nil), title: "", symbol: ""),
            ChatAction(operation: .createBowl(name: "Fresh"), title: "", symbol: ""),
            ChatAction(operation: .move(note: fine.id, bowl: .new("fresh")), title: "", symbol: ""),
        ], in: context, now: now)
        XCTAssertEqual(run.actions.map(\.status), [.failed, .failed, .done, .done])
        XCTAssertEqual(run.actions[0].failure, "The entry is no longer there.")
        XCTAssertNil(link.todoState, "no to-do from a link")
        let fresh = try XCTUnwrap(EntryActions.bowls(named: "Fresh", in: context).first)
        XCTAssertEqual(fine.projectIDs, [Projects.key(fresh)], "into the bowl made in the same go, not a second one")
        XCTAssertEqual(EntryActions.bowls(named: "Fresh", in: context).count, 1)
        EntryActions.undo(run.undo, in: context)
        XCTAssertTrue(fine.projectIDs.isEmpty)
        XCTAssertTrue(EntryActions.bowls(named: "Fresh", in: context).isEmpty)
    }

    func testTheServiceConfirmsCancelsAndUndoes() throws {
        let context = try TestStore.context()
        let entry = note("Plan", in: context)
        try context.save()
        let service = ChatService.shared
        let answerID = UUID()
        let move = ChatAction(operation: .move(note: entry.id, bowl: .new("Projekt X")), title: "Move to new Bowl “Projekt X”", subject: "Plan", symbol: "")
        let tag = ChatAction(operation: .tags(note: entry.id, add: ["q4"], remove: []), title: "Add #q4", subject: "Plan", symbol: "")
        service.setActions([move, tag], for: answerID)

        service.cancel([tag.id], in: answerID)
        service.confirm(in: answerID, context: context)
        XCTAssertEqual(service.actions(for: answerID).map(\.status), [.done, .cancelled])
        XCTAssertEqual(service.toast?.message, "«Plan»: Move to new Bowl “Projekt X”")
        XCTAssertFalse(entry.projectIDs.isEmpty)
        XCTAssertTrue(entry.labels.isEmpty)

        service.undoToast(context: context)
        XCTAssertNil(service.toast)
        XCTAssertTrue(entry.projectIDs.isEmpty)
        XCTAssertEqual(service.actions(for: answerID).map(\.status), [.undone, .cancelled])
        service.setActions([], for: answerID)
    }

    func testProposedActionsAreKeptOnTheDevice() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ChatActionsTests"))
        defaults.removePersistentDomain(forName: "ChatActionsTests")
        let id = UUID()
        let action = ChatAction(operation: .createNote(title: "A", text: "", bowl: .existing("K"), todo: false, due: nil), title: "Create Note", symbol: "square.and.pencil")
        ChatActionStore.save([id: [action]], defaults: defaults)
        XCTAssertEqual(ChatActionStore.load(defaults: defaults)[id], [action])
        defaults.removePersistentDomain(forName: "ChatActionsTests")
    }
}
