import XCTest
@testable import Porridge

/// Smart filters (saved searches): which entries fit, how a search becomes one, how the file merges and is kept,
/// and which entries count as similar to one.
@MainActor
final class SmartFiltersTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SmartFiltersTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private func makeNote(_ title: String, text: String = "", source: NoteSource = .note, created: String = "2026-05-01", bowl: String? = nil) -> Note {
        let note = Note()
        note.title = title
        note.text = text
        note.source = source
        note.createdAt = DocumentInfo.date(fromDay: created)!
        note.updatedAt = note.createdAt
        if let bowl { note.projectIDs = [bowl] }
        return note
    }

    private func document(_ title: String, kind: DocumentKind?, day: String?, sender: String?, created: String = "2026-11-01") -> Note {
        let entry = makeNote(title, source: .share, created: created)
        entry.attachments = [Attachment(fileName: UUID().uuidString + ".pdf", name: title + ".pdf", kindRaw: "pdf")]
        entry.documentInfo = DocumentInfo(kind: kind, day: day, correspondent: sender)
        return entry
    }

    private func meeting(_ title: String, text: String) -> Note {
        let entry = makeNote(title, text: text, source: .meeting)
        entry.audioFileName = "\(UUID().uuidString).m4a"
        return entry
    }

    private func results(_ criteria: SmartFilterCriteria, _ notes: [Note]) -> [String] {
        SmartFilters.results(criteria, in: notes, index: nil).map(\.title)
    }

    // MARK: Matching

    func testInvoicesOfAYearByTheDateOnThem() {
        let notes = [
            document("Telekom März", kind: .invoice, day: "2026-03-02", sender: "Telekom Deutschland GmbH"),
            document("Telekom Dezember", kind: .invoice, day: "2025-12-02", sender: "Telekom Deutschland GmbH", created: "2026-01-05"),
            document("Vertrag", kind: .contract, day: "2026-04-01", sender: "Vermieter"),
            makeNote("Rechnung schreiben", text: "an Anna"),
        ]
        let criteria = SmartFilterCriteria(documentKind: .invoice, from: "2026-01-01", to: "2026-12-31")
        XCTAssertEqual(results(criteria, notes), ["Telekom März"], "the date on the document counts, not when it came in")
    }

    func testSenderMatchesAPartOfTheName() {
        let notes = [
            document("A", kind: .invoice, day: "2026-03-02", sender: "Telekom Deutschland GmbH"),
            document("B", kind: .invoice, day: "2026-03-02", sender: "Vodafone"),
            makeNote("Telekom anrufen"),
        ]
        XCTAssertEqual(results(SmartFilterCriteria(sender: "telekom"), notes), ["A"], "a sender is about documents only, case does not matter")
    }

    func testMeetingsWithAPerson() {
        let notes = [
            meeting("Weekly", text: "Anna presented the plan"),
            meeting("1:1", text: "Bob only"),
            makeNote("Anna's birthday", text: "Gift"),
        ]
        XCTAssertEqual(results(SmartFilterCriteria(text: "Anna", kind: .meetings), notes), ["Weekly"])
    }

    func testLinksInNoBowl() {
        let bowl = UUID().uuidString
        let inbox = makeNote("Swift article", source: .link)
        inbox.url = "https://swift.org"
        let filed = makeNote("Filed article", source: .link, bowl: bowl)
        filed.url = "https://example.com"
        let plain = makeNote("Note in inbox")
        let criteria = SmartFilterCriteria(kind: .links, bowl: SmartFilterCriteria.inbox)
        XCTAssertEqual(results(criteria, [inbox, filed, plain]), ["Swift article"])
        XCTAssertEqual(results(SmartFilterCriteria(bowl: bowl), [inbox, filed, plain]), ["Filed article"])
    }

    func testTagsSourceAndDeletedEntries() {
        let tagged = makeNote("Tagged", text: "Plan #travel and #Food")
        let other = makeNote("Other", text: "#travel")
        let plaud = makeNote("From Plaud", source: .plaud)
        let deleted = makeNote("Gone", text: "#travel #food")
        deleted.deletedAt = Date()
        XCTAssertEqual(results(SmartFilterCriteria(tags: ["#food", "Travel"]), [tagged, other, deleted]), ["Tagged"])
        XCTAssertEqual(results(SmartFilterCriteria(source: .plaud), [tagged, plaud]), ["From Plaud"])
    }

    func testOldEntriesWithoutChannelCountAsNotes() {
        let old = makeNote("Old")
        old.sourceRaw = ""
        XCTAssertTrue(SmartFilterCriteria(source: .note).matches(old))
    }

    func testDateRangeOfOtherEntriesIsWhenTheyCameIn() {
        let notes = [makeNote("May", created: "2026-05-01"), makeNote("June", created: "2026-06-15"), makeNote("July", created: "2026-07-01")]
        XCTAssertEqual(Set(results(SmartFilterCriteria(from: "2026-05-02", to: "2026-07-01"), notes)), ["June", "July"])
        XCTAssertEqual(results(SmartFilterCriteria(to: "2026-05-01"), notes), ["May"])
    }

    func testTextUsesTheIndexWhenItIsThere() {
        let a = makeNote("Alpha", text: "nothing here")
        let b = makeNote("Beta", text: "nothing here")
        let criteria = SmartFilterCriteria(text: "quarterly")
        XCTAssertFalse(criteria.matches(a))
        XCTAssertTrue(criteria.matches(a, textIDs: [a.id]), "the index found the word (in a transcript, say)")
        XCTAssertFalse(criteria.matches(b, textIDs: [a.id]))
    }

    func testDocumentsAreSortedByTheirDate() {
        let older = document("Older", kind: .invoice, day: "2026-01-02", sender: nil)
        let newer = document("Newer", kind: .invoice, day: "2026-06-02", sender: nil)
        newer.updatedAt = .distantPast
        XCTAssertEqual(results(SmartFilterCriteria(documentKind: .invoice), [older, newer]), ["Newer", "Older"])
    }

    func testUnknownValuesMatchNothing() throws {
        let json = #"{"kind":"holograms","text":"x"}"#
        let criteria = try JSONDecoder().decode(SmartFilterCriteria.self, from: Data(json.utf8))
        XCTAssertEqual(criteria.tags, [], "missing keys get their defaults")
        XCTAssertFalse(criteria.matches(makeNote("x", text: "x")), "a kind of a newer app version matches nothing here")
    }

    // MARK: From a search

    func testASearchBecomesKindYearAndWords() {
        let criteria = SmartFilterCriteria.fromSearch(text: "Rechnungen 2026 Telekom", tags: ["steuer"], kind: .files)
        XCTAssertEqual(criteria.document, .invoice)
        XCTAssertEqual(criteria.from, "2026-01-01")
        XCTAssertEqual(criteria.to, "2026-12-31")
        XCTAssertEqual(criteria.wholeYear, 2026)
        XCTAssertEqual(criteria.text, "Telekom")
        XCTAssertEqual(criteria.tags, ["steuer"])
        XCTAssertNil(criteria.kind, "a document kind says more than the Files chip")
        XCTAssertEqual(SmartFilters.suggestedName(for: criteria), "Invoice Telekom #steuer 2026")
    }

    func testAmbiguousWordsStayWords() {
        let criteria = SmartFilterCriteria.fromSearch(text: "Brief an Anna", tags: [], kind: .meetings)
        XCTAssertNil(criteria.documentKind)
        XCTAssertEqual(criteria.text, "Brief an Anna")
        XCTAssertEqual(criteria.entryKind, .meetings)
    }

    func testEmptyCriteria() {
        XCTAssertTrue(SmartFilterCriteria(text: "  ").isEmpty)
        XCTAssertFalse(SmartFilterCriteria(bowl: SmartFilterCriteria.inbox).isEmpty)
    }

    // MARK: Merging the file

    func testTheNewerChangeWins() {
        let id = UUID()
        let old = SmartFilter(id: id, name: "Old", criteria: SmartFilterCriteria(text: "a"), createdAt: Date(timeIntervalSince1970: 100))
        var new = old
        new.name = "New"
        new.updatedAt = Date(timeIntervalSince1970: 200)
        let other = SmartFilter(name: "Other", criteria: SmartFilterCriteria(text: "b"))
        let merged = SmartFilterFile.merged(SmartFilterFile(filters: [old, other]), SmartFilterFile(filters: [new]))
        XCTAssertEqual(merged.filters.map(\.name), ["New", "Other"])
        XCTAssertEqual(SmartFilterFile.merged(SmartFilterFile(filters: [new]), SmartFilterFile(filters: [old])).filters.map(\.name), ["New"])
    }

    func testADeletionIsKeptUnlessTheFilterChangedLater() {
        let now = Date()
        let filter = SmartFilter(name: "A", criteria: SmartFilterCriteria(text: "a"), createdAt: now.addingTimeInterval(-100))
        let deleted = SmartFilterFile(deleted: [filter.id.uuidString: now.addingTimeInterval(-50)])
        XCTAssertTrue(SmartFilterFile.merged(SmartFilterFile(filters: [filter]), deleted, now: now).filters.isEmpty,
                      "a device that still has it does not bring it back")
        var changed = filter
        changed.updatedAt = now.addingTimeInterval(-10)
        XCTAssertEqual(SmartFilterFile.merged(SmartFilterFile(filters: [changed]), deleted, now: now).filters.count, 1)
        let old = SmartFilterFile(deleted: [UUID().uuidString: now.addingTimeInterval(-SmartFilterFile.tombstoneLifetime - 1)])
        XCTAssertTrue(SmartFilterFile.merged(old, SmartFilterFile(), now: now).deleted.isEmpty, "old deletions are forgotten")
    }

    func testAFilterThatDoesNotReadDoesNotTakeTheOthers() throws {
        let json = """
        {"version":1,"filters":[{"id":"not-a-uuid"},{"id":"\(UUID().uuidString)","name":"Kept","criteria":{},"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = SmartFilterStore.dateDecoding
        let file = try decoder.decode(SmartFilterFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.filters.map(\.name), ["Kept"])
    }

    // MARK: Persistence

    func testKeptOnTheDeviceWithoutICloud() async {
        let local = root.appendingPathComponent("local/smart-filters.json")
        let store = SmartFilterStore(localURL: local, cloudFolder: { nil })
        await store.flush()
        XCTAssertTrue(store.filters.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.path), "nothing is written while there is nothing")
        let added = store.add(name: "Rechnungen 2026", criteria: SmartFilterCriteria(documentKind: .invoice, from: "2026-01-01", to: "2026-12-31"))
        store.rename(added.id, to: "Invoices 2026")
        await store.flush()

        let again = SmartFilterStore(localURL: local, cloudFolder: { nil })
        await again.flush()
        XCTAssertEqual(again.filters.map(\.name), ["Invoices 2026"])
        XCTAssertEqual(again.filters.first?.criteria.document, .invoice)
    }

    func testReloadAfterSaveWritesNothing() async throws {
        let cloud = root.appendingPathComponent("cloud", isDirectory: true)
        let local = root.appendingPathComponent("device/smart-filters.json")
        let store = SmartFilterStore(localURL: local, cloudFolder: { cloud })
        await store.flush()
        let made = store.add(name: "Rechnungen", criteria: SmartFilterCriteria(documentKind: .invoice))
        store.rename(made.id, to: "Invoices")
        await store.flush()
        let cloudFile = cloud.appendingPathComponent(SmartFilterStore.fileName)
        func stamp(_ url: URL) throws -> [String] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return ["\(attributes[.systemFileNumber] ?? "")", "\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"]
        }
        let before = (try stamp(local), try stamp(cloudFile))
        for _ in 0..<3 {
            await store.reload()
            await store.flush()
        }
        XCTAssertEqual(try stamp(local), before.0, "a reload with nothing new rewrote the local copy")
        XCTAssertEqual(try stamp(cloudFile), before.1, "a reload with nothing new rewrote the iCloud copy")
    }

    func testDatesSurviveTheFileExactly() {
        let date = Date(timeIntervalSinceReferenceDate: 801_234_567.891_234_5)
        let kept = SmartFilterStore.wholeMillis(date)
        XCTAssertEqual(SmartFilterStore.date(from: SmartFilterStore.dateText(kept)), kept)
        XCTAssertEqual(SmartFilterStore.date(from: SmartFilterStore.dateText(date)), kept)
        XCTAssertEqual(SmartFilterStore.date(from: "2026-01-01T00:00:00Z"), SmartFilterStore.wholeMillis(Date(timeIntervalSince1970: 1_767_225_600)))
        XCTAssertGreaterThan(SmartFilterStore.later(kept, than: kept), kept)
    }

    func testTwoDevicesShareTheFileInICloud() async {
        let cloud = root.appendingPathComponent("cloud", isDirectory: true)
        let phone = SmartFilterStore(localURL: root.appendingPathComponent("phone/smart-filters.json"), cloudFolder: { cloud })
        let mac = SmartFilterStore(localURL: root.appendingPathComponent("mac/smart-filters.json"), cloudFolder: { cloud })
        await phone.flush()
        await mac.flush()

        let made = phone.add(name: "Links ohne Bowl", criteria: SmartFilterCriteria(kind: .links, bowl: SmartFilterCriteria.inbox))
        await phone.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloud.appendingPathComponent(SmartFilterStore.fileName).path))

        await mac.reload()
        XCTAssertEqual(mac.filters.map(\.id), [made.id])

        // Both change at once: each keeps the other's work.
        mac.add(name: "Meetings mit Anna", criteria: SmartFilterCriteria(text: "Anna", kind: .meetings))
        phone.update(made.id, criteria: SmartFilterCriteria(kind: .links))
        await mac.flush()
        await phone.flush()
        await phone.reload()
        await mac.reload()
        XCTAssertEqual(phone.filters.map(\.name), ["Links ohne Bowl", "Meetings mit Anna"])
        XCTAssertEqual(mac.filters.first { $0.id == made.id }?.criteria.bowl, nil, "the phone's later change reached the Mac")

        mac.delete(made.id)
        await mac.flush()
        await phone.reload()
        XCTAssertEqual(phone.filters.map(\.name), ["Meetings mit Anna"])
    }

    func testTurningICloudOnBringsTheFiltersAlong() async {
        let local = root.appendingPathComponent("device/smart-filters.json")
        let cloud = root.appendingPathComponent("cloud", isDirectory: true)
        let offline = SmartFilterStore(localURL: local, cloudFolder: { nil })
        offline.add(name: "Mine", criteria: SmartFilterCriteria(text: "x"))
        await offline.flush()

        let online = SmartFilterStore(localURL: local, cloudFolder: { cloud })
        await online.flush()
        XCTAssertEqual(SmartFilterStore.read(cloud.appendingPathComponent(SmartFilterStore.fileName))?.filters.map(\.name), ["Mine"])
    }

    // MARK: Similar entries

    private func chunk(_ id: UUID, _ text: String, _ vector: [Float]?, part: ChatChunk.Part = .text) -> ChatChunk {
        let words = ChatRetrieval.tokens(text)
        var frequencies: [String: Int] = [:]
        for word in words { frequencies[word, default: 0] += 1 }
        return ChatChunk(noteID: id, title: "", date: Date(), text: text, frequencies: frequencies, prefixFrequencies: [:], length: words.count, part: part, embedding: vector)
    }

    private func normalized(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { $0 / n }
    }

    func testTheMostAlikeComeFirstAndTheEntryItselfNever() {
        let target = UUID(), close = UUID(), closer = UUID(), far = UUID(), excluded = UUID(), todoOnly = UUID()
        let chunks: [UUID: [ChatChunk]] = [
            target: [chunk(target, "budget plan", normalized([1, 0.1, 0, 0]))],
            closer: [chunk(closer, "budget", normalized([1, 0.15, 0, 0]))],
            close: [chunk(close, "plan", normalized([0.8, 0.5, 0.1, 0]))],
            far: [chunk(far, "holiday", normalized([0, 0, 0, 1]))],
            excluded: [chunk(excluded, "budget copy", normalized([1, 0.1, 0, 0]))],
            todoOnly: [chunk(todoOnly, "To-do, open", normalized([1, 0.1, 0, 0]), part: .todo)],
        ]
        let profiles = SimilarEntries.profiles(from: chunks)
        XCTAssertNil(profiles[todoOnly], "a to-do's state alone says nothing about content")
        let matches = SimilarEntries.select(for: target, in: profiles, excluding: [excluded], limit: 5)
        XCTAssertFalse(matches.contains { $0.id == target })
        XCTAssertFalse(matches.contains { $0.id == excluded })
        XCTAssertFalse(matches.contains { $0.id == far }, "only a little alike is left out")
        XCTAssertEqual(matches.first?.id, closer)
        XCTAssertEqual(SimilarEntries.select(for: target, in: profiles, limit: 1).count, 1)
        XCTAssertTrue(SimilarEntries.select(for: UUID(), in: profiles).isEmpty, "an entry the index does not know has none")
    }

    func testWithoutVectorsWordsInCommonCount() {
        let a = UUID(), b = UUID(), c = UUID()
        let chunks: [UUID: [ChatChunk]] = [
            a: [chunk(a, "Kickoff Projekt Phoenix Budget Zeitplan Anna", nil)],
            b: [chunk(b, "Phoenix Budget Zeitplan überarbeitet", nil)],
            c: [chunk(c, "Einkaufsliste Milch Brot", nil)],
        ]
        let matches = SimilarEntries.select(for: a, in: SimilarEntries.profiles(from: chunks))
        XCTAssertEqual(matches.map(\.id), [b])
    }

    func testLinkedToDosAreLeftOut() {
        let source = makeNote("Meeting", text: "Budget plan for Phoenix with the team")
        let todo = makeNote("Budget plan", text: "Budget plan for Phoenix")
        todo.todoSourceID = source.id.uuidString
        let trashed = makeNote("Old plan", text: "Budget plan")
        trashed.deletedAt = Date()
        let unrelated = makeNote("Phoenix notes", text: "Budget")
        XCTAssertEqual(SimilarEntries.excluded(for: source, among: [source, todo, trashed, unrelated]), [todo.id, trashed.id])
        XCTAssertEqual(SimilarEntries.excluded(for: todo, among: [source, todo, trashed, unrelated]), [source.id, trashed.id])
    }
}
