import XCTest
@testable import Porridge

/// Search & Ask (`SearchAsk`): the order of the rows (Ask first, then where to go, then the entries by date), how the
/// Go To rows are ranked, the scope of a search and a chat, the entries that fit, and the recent searches.
@MainActor
final class SearchAskTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func note(_ title: String, text: String = "", bowl: String? = nil, tags: [String] = [], daysAgo: Double = 0) -> Note {
        let note = Note()
        note.title = title
        note.text = text
        note.projectIDs = bowl.map { [$0] } ?? []
        note.labels = tags
        note.updatedAt = now.addingTimeInterval(-daysAgo * 86_400)
        return note
    }

    private func bowl(_ name: String, archived: Bool = false) -> NoteFolder {
        let bowl = NoteFolder(name: name)
        if archived { bowl.archivedAt = now }
        return bowl
    }

    // MARK: Rows

    func testAskComesFirstThenGoToThenEntriesByDate() {
        let bills = bowl("House & Bills")
        let filter = SmartFilter(name: "Unpaid Invoices", criteria: SmartFilterCriteria())
        let old = note("Invoice 1098", daysAgo: 20)
        let new = note("Invoice 1142", daysAgo: 1)
        let targets = SearchAsk.targets(bowls: [bills], filters: [filter], notes: [old, new])
        let entries = SearchAsk.entries([old, new], query: "invoice", indexMatches: nil)
        let rows = SearchAsk.rows(query: " invoice ", targets: targets, entries: entries)
        XCTAssertEqual(rows.first, .ask("invoice"), "the question is the first row, trimmed")
        XCTAssertEqual(rows.dropFirst().first, .goTo(targets.first { $0.title == "Unpaid Invoices" }!))
        XCTAssertEqual(Array(rows.suffix(2)), [.entry(new.id), .entry(old.id)], "entries come last, the newest first")
    }

    func testNothingTypedMeansNoAskAndNoGoTo() {
        let entry = note("Anything")
        let rows = SearchAsk.rows(query: "   ", targets: SearchAsk.places(), entries: [entry])
        XCTAssertEqual(rows, [.entry(entry.id)], "a search by tag or kind alone asks nothing and goes nowhere")
        XCTAssertNil(SearchAsk.question("  \n"))
        XCTAssertTrue(SearchAsk.goTo("", in: SearchAsk.places()).isEmpty)
    }

    // MARK: Go To

    func testSettingsIsAGoToRowAndFoundByItsWords() {
        XCTAssertEqual(SearchAsk.goTo("settings", in: SearchAsk.places()).first?.destination, .settings)
        XCTAssertEqual(SearchAsk.goTo("preferences", in: SearchAsk.places()).first?.destination, .settings, "found by a keyword too")
        XCTAssertEqual(SearchAsk.goTo("open to", in: SearchAsk.places()).first?.destination, .openTodos)
    }

    func testAMatchInTheNameBeatsOneInTheKeywords() {
        // "Weekly Review" has "summary" among its words; a bowl named "Summary" matches by its name.
        let targets = SearchAsk.targets(bowls: [bowl("Summary")], filters: [], notes: [])
        XCTAssertEqual(SearchAsk.goTo("summary", in: targets).first?.title, "Summary")
    }

    func testEqualMatchesPutPlacesBeforeSmartFiltersBeforeBowlsAndArchivedLast() {
        let filter = SmartFilter(name: "Inbox", criteria: SmartFilterCriteria())
        let targets = SearchAsk.targets(bowls: [bowl("Inbox", archived: true), bowl("Inbox")], filters: [filter], notes: [])
        let all = SearchAsk.goTo("inbox", in: targets)
        // "Triage Inbox" (a command since stage 6) matches only at its second word: after every name that starts so.
        XCTAssertEqual(all.last?.destination, .triage)
        let found = all.filter { $0.destination != .triage }
        XCTAssertEqual(found.map(\.kind), [.place, .smartFilter, .bowl, .bowl])
        XCTAssertEqual(found.last?.isArchived, true, "an archived bowl comes after the others")
    }

    func testTargetsCountTheirEntries() {
        let bills = bowl("Bills")
        let key = Projects.key(bills)
        let deleted = note("Gone", bowl: key)
        deleted.deletedAt = now
        let targets = SearchAsk.targets(bowls: [bills], filters: [], notes: [note("A", bowl: key), note("B", bowl: key), deleted], places: false)
        XCTAssertEqual(targets.map(\.subtitle), ["Bowl · 2 entries"])
        XCTAssertEqual(SearchAsk.entriesText(1), "1 entry")
    }

    func testGoToIsLimited() {
        let targets = SearchAsk.targets(bowls: (1...9).map { bowl("Trip \($0)") }, filters: [], notes: [], places: false)
        XCTAssertEqual(SearchAsk.goTo("trip", in: targets, limit: 5).count, 5)
    }

    func testGoToNeedsWordStartsNotScatteredLetters() {
        let targets = SearchAsk.targets(
            bowls: [bowl("Kitchen Renovation"), bowl("Q4 Planning"), bowl("Chk")], filters: [], notes: [], places: false
        )
        XCTAssertTrue(SearchAsk.goTo("cha", in: targets).isEmpty, "c…h…a scattered through Kitchen Renovation is no match")
        XCTAssertEqual(SearchAsk.goTo("q4", in: targets).map(\.title), ["Q4 Planning"])
        XCTAssertEqual(SearchAsk.goTo("chk", in: targets).map(\.title), ["Chk"])
        XCTAssertEqual(SearchAsk.goTo("reno", in: targets).map(\.title), ["Kitchen Renovation"], "the start of a later word")
        XCTAssertEqual(SearchAsk.goTo("vation", in: targets).map(\.title), ["Kitchen Renovation"], "a longer run inside a word")
        XCTAssertTrue(SearchAsk.goTo("vat", in: targets).isEmpty, "three letters inside a word are not enough")
    }

    /// The Mac's commands are matched by `SearchAsk.score` (title and extra words) — the findings that made "design"
    /// preselect Record Meeting and "Chk" New Chat.
    func testCommandsMatchByNameAndWordStartsOnly() throws {
        XCTAssertNil(SearchAsk.score("design", title: "Record Meeting", keywords: "start recording calendar appointment"))
        XCTAssertNil(SearchAsk.score("chk", title: "New Chat", keywords: "ask question chat"))
        XCTAssertNil(SearchAsk.score("bow", title: "Export Everything…", keywords: "backup markdown"))
        XCTAssertNil(SearchAsk.score("bow", title: "Go to Archive", keywords: "show archived"))
        XCTAssertNil(SearchAsk.score("cha", title: "Kitchen Renovation"))
        XCTAssertNotNil(SearchAsk.score("bow", title: "Go to Bowls", keywords: "show all bowls"))
        XCTAssertNotNil(SearchAsk.score("rm", title: "Record Meeting"), "first letters of the words")
        XCTAssertNotNil(SearchAsk.score("chat", title: "New Chat"))
        XCTAssertNotNil(SearchAsk.score("preferences", title: "Settings", keywords: "open preferences options"), "an extra word")
        XCTAssertNil(SearchAsk.score("pr", title: "Settings", keywords: "open preferences options"), "extra words only from three letters")
        let byName = try XCTUnwrap(SearchAsk.score("settings", title: "Settings", keywords: "preferences"))
        let byWord = try XCTUnwrap(SearchAsk.score("preferences", title: "Settings", keywords: "preferences"))
        XCTAssertGreaterThan(byName, byWord, "the name beats an extra word")
    }

    func testFitOfANameToWhatWasTyped() {
        XCTAssertEqual(SearchAsk.fit("chk", name: "Chk"), .exact)
        XCTAssertEqual(SearchAsk.fit(" Design ", name: "Design Review"), .start)
        XCTAssertEqual(SearchAsk.fit("review", name: "Design Review"), .words)
        XCTAssertEqual(SearchAsk.fit("q4", name: "Q4 Planning"), .start)
        XCTAssertEqual(SearchAsk.fit("view", name: "Design Review"), .loose)
        XCTAssertEqual(SearchAsk.fit("rm", name: "Record Meeting"), .loose)
    }

    func testReturnNeverRunsAnActionOverAnEntryOrBowlThatFitsAsWell() {
        // "design": Record Meeting (found loosely) and the entry "Design Review".
        XCTAssertEqual(SearchAsk.best([(.loose, .action), (.start, .entry)]), 1)
        // "Chk": the bowl, its entries, New Chat (loosely).
        XCTAssertEqual(SearchAsk.best([(.loose, .action), (.exact, .bowl), (.start, .entry)]), 1)
        // "new note" typed: the command fits exactly, an entry only by its text.
        XCTAssertEqual(SearchAsk.best([(.exact, .action), (.loose, .entry)]), 0)
        // An entry named exactly like the command wins the tie.
        XCTAssertEqual(SearchAsk.best([(.exact, .action), (.exact, .entry)]), 1)
        // "bow": Go to Bowls (a place) over a loosely found entry.
        XCTAssertEqual(SearchAsk.best([(.start, .place), (.loose, .entry)]), 0)
        // Only an action found loosely: nothing is chosen (Show All Results is).
        XCTAssertNil(SearchAsk.best([(.loose, .action)]))
        XCTAssertEqual(SearchAsk.best([(.loose, .action), (.loose, .entry)]), 1)
    }

    // MARK: Entries

    func testEntriesFitScopeKindTagsAndText() {
        let inbox = note("Telekom invoice", tags: ["bills"])
        let filed = note("Telekom contract", bowl: "house", tags: ["Bills"])
        let other = note("Holiday", bowl: "house")
        let todo = note("Pay Telekom", bowl: "house")
        todo.todoState = .open
        let gone = note("Telekom old")
        gone.deletedAt = now
        let all = [inbox, filed, other, todo, gone]
        XCTAssertEqual(Set(SearchAsk.entries(all, query: "telekom", indexMatches: nil).map(\.title)), ["Telekom invoice", "Telekom contract", "Pay Telekom"])
        XCTAssertEqual(SearchAsk.entries(all, query: "telekom", scope: .inbox, indexMatches: nil).map(\.title), ["Telekom invoice"])
        XCTAssertEqual(Set(SearchAsk.entries(all, query: "", scope: .bowl("house"), indexMatches: nil).map(\.title)), ["Telekom contract", "Holiday", "Pay Telekom"])
        XCTAssertEqual(Set(SearchAsk.entries(all, query: "", tags: ["BILLS"], indexMatches: nil).map(\.title)), ["Telekom invoice", "Telekom contract"])
        XCTAssertEqual(SearchAsk.entries(all, query: "telekom", kind: { $0.isTodo }, indexMatches: nil).map(\.title), ["Pay Telekom"])
    }

    func testTheIndexFindsWordsInsideAnEntry() {
        let meeting = note("Weekly", text: "")
        let unrelated = note("Shopping")
        let found = SearchAsk.entries([meeting, unrelated], query: "budget", indexMatches: [meeting.id])
        XCTAssertEqual(found.map(\.id), [meeting.id])
    }

    func testDateGroupsKeepTheirOrder() {
        let notes = [note("a", daysAgo: 0), note("b", daysAgo: 1), note("c", daysAgo: 3), note("d", daysAgo: 20)]
        let groups = SearchAsk.dateGroups(notes, now: now)
        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days"])
    }

    // MARK: Scope

    func testScopeIsKeptAsTheChatsBowlKey() {
        for scope in [SearchAsk.Scope.everywhere, .inbox, .bowl("B1")] {
            XCTAssertEqual(SearchAsk.Scope(chatKey: scope.chatKey), scope)
        }
        XCTAssertNil(SearchAsk.Scope.everywhere.chatKey)
        XCTAssertEqual(SearchAsk.chatName(nil, bowls: []), "All Bowls")
        XCTAssertEqual(SearchAsk.chatName(SearchAsk.inboxKey, bowls: []), "Inbox")
        XCTAssertEqual(SearchAsk.searchName(.everywhere, bowls: []), "Everywhere")
        let bills = bowl("Bills")
        XCTAssertEqual(SearchAsk.askSubtitle(.bowl(Projects.key(bills)), bowls: [bills]), "Answers with sources · Bills")
        XCTAssertEqual(SearchAsk.askTitle("telekom invoice"), "Ask Porridge: “telekom invoice”")
    }

    // MARK: Recent

    func testRecentSearchesKeepTenLatestFirstEachOnce() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SearchAskTests"))
        defer { defaults.removePersistentDomain(forName: "SearchAskTests") }
        SearchAsk.RecentSearches.clear(in: defaults)
        for index in 1...12 { SearchAsk.RecentSearches.add("query \(index)", in: defaults) }
        SearchAsk.RecentSearches.add("Query 5", in: defaults)
        SearchAsk.RecentSearches.add("   ", in: defaults)
        SearchAsk.RecentSearches.add("unpaid", tags: ["bills"], in: defaults)
        let all = SearchAsk.RecentSearches.all(in: defaults)
        XCTAssertEqual(all.count, 10)
        XCTAssertEqual(Array(all.prefix(2)), ["#bills unpaid", "Query 5"])
        XCTAssertEqual(all.filter { $0.lowercased() == "query 5" }.count, 1)
        let parsed = SearchAsk.RecentSearches.parse("#Bills unpaid #nosuchtag", known: ["bills"])
        XCTAssertEqual(parsed.tags, ["bills"])
        XCTAssertEqual(parsed.text, "unpaid #nosuchtag")
    }

    func testRecentChatsAreTheLatestThree() {
        let chats = (0..<5).map { index -> ChatThread in
            let chat = ChatThread()
            chat.title = "\(index)"
            chat.updatedAt = now.addingTimeInterval(Double(index))
            return chat
        }
        XCTAssertEqual(SearchAsk.recentChats(chats).map(\.title), ["4", "3", "2"])
    }
}
