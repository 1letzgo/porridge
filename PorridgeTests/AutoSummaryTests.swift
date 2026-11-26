import XCTest
@testable import Porridge

/// Summaries of incoming entries (`AutoSummary`): which entries, when, on which device, and never over the user.
@MainActor
final class AutoSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let page = String(repeating: "Ein Artikel über Sauerteig, Roggenmehl und lange Gare. ", count: 8)
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "AutoSummaryTests")
        defaults.removePersistentDomain(forName: "AutoSummaryTests")
    }

    private func entry(_ configure: (Note) -> Void) -> Note {
        let note = Note()
        note.createdAt = now.addingTimeInterval(-60)
        note.updatedAt = now.addingTimeInterval(-60)
        configure(note)
        return note
    }

    private func link(page: String? = nil) -> Note {
        entry { note in
            note.url = "https://example.com/sauerteig"
            note.source = .link
            note.pageText = page ?? self.page
        }
    }

    private func due(_ note: Note, origin: Bool = true, enabled: Bool = true) -> Bool {
        AutoSummary.isDue(note, isOrigin: origin, enabled: enabled, now: now)
    }

    // MARK: - Which entries

    func testIncomingEntriesAreSummarized() {
        XCTAssertEqual(AutoSummary.kind(of: link()), .link)
        XCTAssertTrue(due(link()))

        let image = entry { note in
            note.source = .share
            note.attachments = [Attachment(fileName: "a.jpg", name: "IMG.jpg", kindRaw: "image")]
            note.pageText = self.page
        }
        XCTAssertEqual(AutoSummary.kind(of: image), .image)
        XCTAssertTrue(due(image))

        let file = entry { note in
            note.source = .share
            note.attachments = [Attachment(fileName: "a.pdf", name: "Vertrag.pdf", kindRaw: "pdf")]
            note.pageText = self.page
        }
        XCTAssertEqual(AutoSummary.kind(of: file), .file)
        XCTAssertTrue(due(file))

        let shared = entry { note in
            note.source = .share
            note.text = self.page
        }
        XCTAssertEqual(AutoSummary.kind(of: shared), .sharedText)
        XCTAssertTrue(due(shared))

        // Audio shared from another app is imported audio as well.
        // A recording from a channel this version does not know counts as imported audio.
        for source in [NoteSource.audioImport.rawValue, "legacy-device", NoteSource.share.rawValue] {
            let audio = entry { note in
                note.sourceRaw = source
                note.audioFileName = "a.m4a"
                note.segments = [TranscriptSegment(start: 0, end: 60, text: self.page)]
            }
            XCTAssertEqual(AutoSummary.kind(of: audio), .importedAudio)
            XCTAssertTrue(due(audio))
        }
    }

    func testSharedAudioGivesToDosLinksAndSharedTextNever() throws {
        let context = try TestStore.context()
        let tasks = "## Action Items\n- [ ] Angebot schicken"

        let sharedAudio = entry { note in
            note.source = .share
            note.audioFileName = "a.m4a"
            note.segments = [TranscriptSegment(start: 0, end: 60, text: self.page)]
        }
        XCTAssertFalse(sharedAudio.isSaved, "shared audio is treated like imported audio")
        sharedAudio.summary = tasks
        TodoSuggestions.offer(sharedAudio)
        XCTAssertTrue(sharedAudio.offersTodoSuggestions)
        XCTAssertNotNil(Todos.create(fromTask: "Angebot schicken", of: sharedAudio, in: context))

        // Still being transcribed: already an audio entry, not shared text.
        let transcribing = entry { note in
            note.source = .share
            note.audioFileName = "b.m4a"
        }
        XCTAssertFalse(transcribing.isSaved)
        XCTAssertEqual(AutoSummary.kind(of: transcribing), .importedAudio)

        let sharedText = entry { note in
            note.source = .share
            note.text = self.page
        }
        let sharedFile = entry { note in
            note.source = .share
            note.attachments = [Attachment(fileName: "a.pdf", name: "Vertrag.pdf", kindRaw: "pdf")]
            note.pageText = self.page
        }
        let sharedLinkWithText = entry { note in
            note.source = .share
            note.url = "https://example.com/a"
            note.text = self.page
        }
        for saved in [link(), sharedText, sharedFile, sharedLinkWithText] {
            XCTAssertTrue(saved.isSaved)
            saved.summary = tasks
            TodoSuggestions.offer(saved)
            XCTAssertFalse(saved.offersTodoSuggestions, "links and shared text or pages never give to-dos")
            XCTAssertNil(Todos.create(fromTask: "Angebot schicken", of: saved, in: context))
        }
    }

    func testOwnNotesToDosAndRecordingsAreNot() {
        let own = entry { $0.text = self.page }
        XCTAssertNil(AutoSummary.kind(of: own))
        XCTAssertFalse(due(own))

        let todo = entry { note in
            note.source = .share
            note.text = self.page
            note.todoState = .open
        }
        XCTAssertNil(AutoSummary.kind(of: todo), "a to-do is the user's own, wherever it came from")

        let recording = entry { note in
            note.source = .meeting
            note.audioFileName = "m.m4a"
            note.segments = [TranscriptSegment(start: 0, end: 60, text: self.page)]
        }
        XCTAssertNil(AutoSummary.kind(of: recording), "own meetings are summarized when asked, with a template")

        let ownWithFile = entry { note in
            note.text = "Mein Text"
            note.attachments = [Attachment(fileName: "a.pdf", name: "a.pdf", kindRaw: "pdf")]
            note.pageText = self.page
        }
        XCTAssertNil(AutoSummary.kind(of: ownWithFile), "a note that got a file attached stays a note")
    }

    func testNotWhenThereIsLittleOrNoTextYet() {
        XCTAssertFalse(due(link(page: "Kurz.")), "too little to summarize")
        XCTAssertFalse(due(link(page: "")), "a page that could not be read")
        let loading = link()
        loading.status = .recorded
        XCTAssertFalse(due(loading), "the page is still being loaded")
        let photo = entry { note in
            note.source = .share
            note.attachments = [Attachment(fileName: "a.jpg", name: "IMG.jpg", kindRaw: "image")]
            note.pageText = ""
        }
        XCTAssertFalse(due(photo), "a photo without text")
        let transcribing = entry { note in
            note.source = .audioImport
            note.audioFileName = "a.m4a"
            note.status = .transcribing
        }
        XCTAssertFalse(due(transcribing))
    }

    func testNotWhenOffDeletedOrAlreadySummarized() {
        XCTAssertFalse(due(link(), enabled: false), "Summarize Incoming Entries is off")
        let deleted = link()
        deleted.deletedAt = now
        XCTAssertFalse(due(deleted))
        let summarized = link()
        summarized.summary = "## Zusammenfassung\nSchon da."
        XCTAssertFalse(due(summarized), "never twice")
        let editing = link()
        editing.summary = ""
        XCTAssertFalse(due(editing), "the user is writing one")
    }

    /// A summary the user deleted does not come back by itself; an editor closed on nothing does not block it.
    func testADeletedSummaryStaysDeleted() {
        let note = link()
        note.summary = "Text"
        note.summarizedAt = now
        SummaryService.removeSummary(note)
        XCTAssertNil(note.summary)
        XCTAssertNotNil(note.summarizedAt)
        XCTAssertFalse(due(note))

        let never = link()
        never.summary = ""
        SummaryService.removeSummary(never)
        XCTAssertTrue(due(never))
    }

    // MARK: - Which device

    func testTheDeviceItCameInOnSummarizesOthersCatchUpLater() {
        let fresh = link()
        XCTAssertTrue(due(fresh, origin: true))
        XCTAssertFalse(due(fresh, origin: false), "another device leaves it to the device it came in on")

        let waiting = link()
        waiting.updatedAt = now.addingTimeInterval(-AutoSummary.catchUpDelay - 1)
        XCTAssertTrue(due(waiting, origin: false), "no summary after two hours: another device catches up")

        let old = link()
        old.createdAt = now.addingTimeInterval(-40 * 86400)
        old.updatedAt = old.createdAt
        XCTAssertFalse(due(old, origin: false), "no catching up on everything ever saved")
        XCTAssertTrue(due(old, origin: true))
    }

    func testOriginsAreKeptOnThisDeviceAndPruned() {
        let a = link(), b = link(), c = link()
        AutoSummary.markOrigin(a.id, defaults)
        AutoSummary.markOrigin(b.id, defaults)
        AutoSummary.markOrigin(c.id, defaults)
        AutoSummary.markOrigin(c.id, defaults)
        XCTAssertTrue(AutoSummary.isOrigin(a.id, defaults))
        AutoSummary.clearOrigin(a.id, defaults)
        XCTAssertFalse(AutoSummary.isOrigin(a.id, defaults))
        // b got its summary (from another device), c is still waiting; a note that is gone drops out too.
        b.summary = "Fertig"
        AutoSummary.pruneOrigins(keeping: [b, c], defaults)
        XCTAssertEqual(AutoSummary.origins(defaults), [c.id.uuidString])
    }

    /// An entry from another device arrives by sync: its summary comes along, or it is not summarized twice.
    func testASyncedSummaryAndItsDeletionAreNotRedone() {
        let copy = link()
        copy.summary = "## Zusammenfassung\nSauerteig."
        copy.summarizedAt = now
        XCTAssertFalse(due(copy, origin: false))
        XCTAssertFalse(due(copy, origin: true))

        // Deleted on the other device: no summary, but summarizedAt stays.
        SummaryService.removeSummary(copy)
        copy.updatedAt = now.addingTimeInterval(-AutoSummary.catchUpDelay - 1)
        XCTAssertNil(copy.summary)
        XCTAssertNotNil(copy.summarizedAt)
        XCTAssertFalse(due(copy, origin: false), "a deleted summary does not come back on another device")

        // A link that came in elsewhere and has no summary yet: left to that device, caught up later.
        XCTAssertFalse(due(link(), origin: false))
    }

    // MARK: - Attempts

    func testFailuresAreRetriedQuietlyAndNotForever() {
        var attempts = AutoSummary.Attempts()
        let id = UUID()
        XCTAssertTrue(attempts.mayTry(id, now: now))
        attempts.failed(id, at: now)
        XCTAssertFalse(attempts.mayTry(id, now: now.addingTimeInterval(60)))
        XCTAssertTrue(attempts.mayTry(id, now: now.addingTimeInterval(AutoSummary.retryDelay)))
        attempts.failed(id, at: now)
        attempts.failed(id, at: now)
        XCTAssertFalse(attempts.mayTry(id, now: now.addingTimeInterval(10 * AutoSummary.retryDelay)), "three times per launch")
        attempts.succeeded(id)
        XCTAssertTrue(attempts.mayTry(id, now: now))
    }

    // MARK: - Around it

    func testALinkGetsNoToDoSuggestions() {
        let note = link()
        TodoSuggestions.offer(note)
        XCTAssertNil(note.todoSuggestionsRaw)
    }

    func testTheChatIndexTakesTheNewSummary() {
        let note = link()
        let before = note.indexHash
        note.summary = "## Zusammenfassung\nSauerteig braucht Zeit."
        XCTAssertNotEqual(before, note.indexHash, "the index cuts the entry again")
        XCTAssertEqual(ChatDocument(note: note).snippet, "Sauerteig braucht Zeit.", "the chat's entry starts with the summary")
        XCTAssertTrue(ChatRetrieval.chunks(from: [note]).contains { $0.part == .summary })
    }
}
