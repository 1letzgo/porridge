import SwiftData
import XCTest
@testable import Porridge

/// ✦ AI · Share · ⋯ More per kind: the contract of the design's table (HTML 3.1), row by row.
@MainActor
final class EntryMenusTests: XCTestCase {
    private typealias F = EntryFixtures

    private func ai(_ note: Note, _ state: EntryContext = EntryContext()) -> [[EntryMenus.AIItem]] {
        EntryMenus.ai(for: note, context: state)
    }

    private func more(_ note: Note, _ state: EntryContext = EntryContext(), on platform: EntryMenus.Platform = .iPhone) -> [[EntryMenus.MoreItem]] {
        EntryMenus.more(for: note, context: state, platform: platform)
    }

    func testNote() throws {
        let context = try TestStore.context()
        let note = F.note(text: "Some text", in: context)
        XCTAssertEqual(ai(note), [[.enhance, .rewriteSelection, .splitIntoBowl]])
        var enhanced = EntryContext()
        enhanced.canUndoEnhance = true
        note.summary = "Earlier summary"
        XCTAssertEqual(ai(note, enhanced), [[.enhance, .undoEnhance, .summarize(again: true), .rewriteSelection, .splitIntoBowl]])
        XCTAssertEqual(EntryMenus.share(for: note), .markdown)
        XCTAssertEqual(more(note), [[.pin, .convertToTodo, .later], [.saveAsTemplate], [.delete]])

        // In a bowl: Ask About This Bowl, no Later.
        let work = F.bowl("Work", in: context)
        F.file(note, into: work)
        XCTAssertEqual(ai(note).last, [.askAboutBowl])
        XCTAssertEqual(more(note), [[.pin, .convertToTodo], [.saveAsTemplate], [.delete]])
    }

    func testTodo() throws {
        let context = try TestStore.context()
        let todo = F.todo(text: "- [ ] One", in: context)
        XCTAssertEqual(ai(todo), [[.enhance, .rewriteSelection, .splitIntoBowl]], "a to-do is enhanced, not summarized")
        XCTAssertEqual(EntryMenus.share(for: todo), .todoText)
        XCTAssertEqual(more(todo), [[.pin, .markDone, .convertToNote, .later], [.saveAsTemplate], [.delete]])
        XCTAssertEqual(EntryMenus.MoreItem.markDone.title(for: todo), "Mark as Done")
        todo.todoState = .done
        XCTAssertEqual(EntryMenus.MoreItem.markDone.title(for: todo), "Mark as Not Done")
    }

    func testMeeting() throws {
        let context = try TestStore.context()
        let meeting = F.meeting(in: context)
        XCTAssertEqual(ai(meeting), [[.summarize(again: false), .suggestTodos, .splitIntoBowl]])
        meeting.summary = "Decisions"
        XCTAssertEqual(ai(meeting).first?.first, .summarize(again: true))
        XCTAssertEqual(EntryMenus.share(for: meeting), .exportSheet)
        XCTAssertEqual(more(meeting), [
            [.pin, .later],
            [.continueRecording, .transcribeAgain, .mergeWith, .copyTranscript, .deleteRecording],
            [.saveAsTemplate],
            [.delete],
        ])
        // The Mac adds Open in New Window before Delete.
        XCTAssertEqual(more(meeting, on: .mac).suffix(2), [[.openInNewWindow], [.delete]])
    }

    func testLinkNeverSuggestsTodos() throws {
        let context = try TestStore.context()
        let link = F.link(in: context)
        XCTAssertEqual(ai(link), [[.summarize(again: false)]])
        link.summary = "Page summary"
        let work = F.bowl("Work", in: context)
        F.file(link, into: work)
        XCTAssertEqual(ai(link), [[.summarize(again: true)], [.askAboutBowl]])
        XCTAssertFalse(ai(link).joined().contains(.suggestTodos))
        XCTAssertEqual(EntryMenus.share(for: link), .url)
        XCTAssertEqual(more(link), [[.pin, .openInBrowser, .copyLink, .loadPageAgain], [.delete]])
    }

    func testImage() throws {
        let context = try TestStore.context()
        let image = F.image(in: context)
        XCTAssertEqual(ai(image), [[.summarize(again: false)]])
        XCTAssertEqual(EntryMenus.share(for: image), .image)
        XCTAssertEqual(more(image), [[.pin, .later], [.delete]])
        // A photographed bill: Mark as Paid.
        var list = image.attachments
        list[0].document = DocumentInfo(kind: .invoice, correspondent: "Bakery", isEdited: true)
        image.attachments = list
        XCTAssertEqual(more(image).first, [.pin, .markPaid, .later])
    }

    func testDocument() throws {
        let context = try TestStore.context()
        let bill = F.pdf(document: DocumentInfo(kind: .invoice), in: context)
        XCTAssertEqual(ai(bill), [[.summarize(again: false)]])
        XCTAssertEqual(EntryMenus.share(for: bill), .file)
        XCTAssertEqual(more(bill), [[.pin, .markPaid, .editPages, .scanMorePages, .later], [.delete]])
        // Scan More Pages is the iPhone's; the Mac has Open in New Window.
        XCTAssertEqual(more(bill, on: .mac), [[.pin, .markPaid, .editPages, .later], [.openInNewWindow], [.delete]])
        XCTAssertEqual(EntryMenus.MoreItem.markPaid.title(for: bill), "Mark as Paid")
        // A letter asks for no payment.
        let letter = F.pdf(document: DocumentInfo(kind: .letter), in: context)
        XCTAssertEqual(more(letter).first, [.pin, .editPages, .scanMorePages, .later])
    }

    func testRecentlyDeleted() throws {
        let context = try TestStore.context()
        for note in [F.note(in: context), F.meeting(in: context), F.link(in: context), F.pdf(in: context)] {
            NoteStore.trash(note, in: context)
            XCTAssertEqual(ai(note), [])
            XCTAssertNil(EntryMenus.share(for: note))
            XCTAssertEqual(more(note), [[.recover, .deleteNow]])
            XCTAssertEqual(more(note, on: .mac), [[.recover, .deleteNow]])
        }
    }

    func testViewOnly() throws {
        let context = try TestStore.context()
        var viewOnly = EntryContext()
        viewOnly.isReadOnly = true
        let shared = F.bowl("Shared", in: context)
        for note in [F.note(in: context), F.meeting(in: context), F.todo(in: context)] {
            F.file(note, into: shared)
            XCTAssertEqual(ai(note, viewOnly), [[.askAboutBowl]])
            XCTAssertEqual(more(note, viewOnly), [[.pin, .copy, .saveAsTemplate]])
            XCTAssertEqual(more(note, viewOnly, on: .mac), [[.pin, .copy, .saveAsTemplate], [.openInNewWindow]])
        }
    }

    func testEveryItemHasATitle() throws {
        let context = try TestStore.context()
        let note = F.note(in: context)
        let items: [EntryMenus.MoreItem] = [
            .pin, .markDone, .convertToTodo, .convertToNote, .later, .markPaid, .editPages, .scanMorePages, .openInBrowser, .copyLink,
            .loadPageAgain, .continueRecording, .transcribeAgain, .mergeWith, .copyTranscript, .deleteRecording, .saveAsTemplate, .copy,
            .openInNewWindow, .delete, .recover, .deleteNow,
        ]
        XCTAssertTrue(items.allSatisfy { !$0.title(for: note).isEmpty })
        XCTAssertEqual(EntryMenus.AIItem.summarize(again: false).title, "Summarize…")
        XCTAssertEqual(EntryMenus.AIItem.summarize(again: true).title, "Summarize Again…")
    }
}
