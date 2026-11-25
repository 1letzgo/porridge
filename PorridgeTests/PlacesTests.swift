import XCTest
@testable import Porridge

/// The three places: the counts on Today's and the Inbox's tab (and the Mac's sidebar rows), Today's Up Next and its
/// Weekly Review row, the links and shortcuts that open a place, and where a page belongs.
@MainActor
final class PlacesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func day(_ offset: Int) -> String {
        Todos.dueKey(Calendar.current.date(byAdding: .day, value: offset, to: now)!)
    }

    private func todo(_ title: String, due: String?, done: Bool = false, deleted: Bool = false) -> Note {
        let note = Note()
        note.title = title
        note.todoState = done ? .done : .open
        note.todoDueDay = due
        note.projectIDs = ["bowl"]
        if deleted { note.deletedAt = now }
        return note
    }

    func testTodayCountsOpenTodosDueTodayOrBefore() {
        let notes = [
            todo("late", due: day(-3)),
            todo("today", due: day(0)),
            todo("tomorrow", due: day(1)),
            todo("undated", due: nil),
            todo("done", due: day(0), done: true),
            todo("deleted", due: day(0), deleted: true),
        ]
        XCTAssertEqual(Places.todayCount(notes, now: now), 2)
    }

    func testInboxCountsWhatWaitsNotWhatIsLaterOrFiled() {
        let waiting = Note()
        let filed = Note()
        filed.projectIDs = ["bowl"]
        let later = Note()
        later.snoozedUntil = now.addingTimeInterval(3600)
        let deleted = Note()
        deleted.deletedAt = now
        XCTAssertEqual(Places.inboxCount([waiting, filed, later, deleted], now: now), 1)
    }

    func testUpNextIsTheNextSevenDaysByDue() {
        let notes = [
            todo("in eight", due: day(8)),
            todo("in two", due: day(2)),
            todo("today", due: day(0)),
            todo("in seven", due: day(7)),
            todo("tomorrow", due: day(1)),
            todo("done", due: day(3), done: true),
        ]
        XCTAssertEqual(TodayTodos.upcoming(notes, now: now).map(\.title), ["tomorrow", "in two", "in seven"])
    }

    func testNewThisWeekCountsEntriesOfTheWeek() {
        let fresh = Note()
        fresh.createdAt = now
        let old = Note()
        old.createdAt = now.addingTimeInterval(-30 * 86_400)
        let gone = Note()
        gone.createdAt = now
        gone.deletedAt = now
        XCTAssertEqual(Places.newThisWeek([fresh, old, gone], now: now), 1)
    }

    /// `porridge://today`, `porridge://bowls`, `porridge://todos` and `porridge://inbox` open their place.
    func testPlaceLinks() {
        XCTAssertEqual(QuickAction(url: URL(string: "porridge://today")!), .openToday)
        XCTAssertEqual(QuickAction(url: URL(string: "porridge://bowls")!), .openBowls)
        XCTAssertEqual(QuickAction(url: URL(string: "porridge://todos")!), .openTodos)
        XCTAssertEqual(QuickAction(url: URL(string: "porridge://inbox")!), .openInbox)
        XCTAssertEqual(QuickAction.openToday.url.absoluteString, "porridge://today")
        XCTAssertEqual(QuickAction.openBowls.url.absoluteString, "porridge://bowls")
    }

    /// Each page opened from elsewhere lands on its place's stack: Open To-dos on Today, the bowls' pages and Settings
    /// on Bowls, the chat on the search.
    func testPagesBelongToTheirPlace() {
        XCTAssertEqual(ListPage.todos.place, .today)
        XCTAssertEqual(ListPage.project(UUID()).place, .bowls)
        XCTAssertEqual(ListPage.smartFilter(UUID()).place, .bowls)
        XCTAssertEqual(ListPage.archive.place, .bowls)
        XCTAssertEqual(ListPage.trash.place, .bowls)
        XCTAssertEqual(ListPage.settings.place, .bowls)
        XCTAssertEqual(ListPage.chat.place, .chat)
        XCTAssertEqual(Place(root: .inbox), .inbox)
        XCTAssertNil(Place(root: .todos))
        XCTAssertEqual(Place.allCases.map(\.root), [.today, .inbox, .bowls, .chat, .search])
    }

    /// An entry link waits until the entry can be opened (cold start: before the list has loaded it).
    func testEntryLinkWaitsUntilTaken() {
        let id = UUID()
        XCTAssertTrue(EntryLinkRouter.handle(URL(string: "porridge://entry/\(id.uuidString)")!))
        XCTAssertEqual(EntryLinkRouter.waiting, id)
        XCTAssertEqual(EntryLinkRouter.waiting, id, "looking does not take it")
        XCTAssertEqual(EntryLinkRouter.take(), id)
        XCTAssertNil(EntryLinkRouter.waiting)
    }

    /// Five tabs in this order; the chat is a place of its own (owner decision, revision 3).
    func testTheTabsAreTheFourPlacesAndTheSearch() {
        XCTAssertEqual(Place.allCases, [.today, .inbox, .bowls, .chat, .search])
        XCTAssertEqual(ListPage.chat.place, .chat)
        XCTAssertEqual(Place(root: .chat), .chat)
        XCTAssertEqual(ListPage.search.place, .search)
    }

    func testTheChatLinkOpensTheChat() {
        XCTAssertEqual(QuickAction(url: URL(string: "porridge://chat")!), .openChat)
        XCTAssertEqual(QuickAction.openChat.url.absoluteString, "porridge://chat")
    }

    // MARK: What's New

    func testWhatsNewShowsOnceAfterAnEarlierVersionAndNeverAfterOnboarding() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WhatsNewTests"))
        defaults.removePersistentDomain(forName: "WhatsNewTests")
        defer { defaults.removePersistentDomain(forName: "WhatsNewTests") }
        XCTAssertFalse(WhatsNew.shows(in: defaults), "a new install sees the onboarding, not the card")
        defaults.set(true, forKey: AppSettings.onboardingDoneKey)
        XCTAssertTrue(WhatsNew.shows(in: defaults), "someone who used an earlier version sees it")
        WhatsNew.dismiss(in: defaults)
        XCTAssertFalse(WhatsNew.shows(in: defaults), "once put away it stays away")
    }

    func testWhatsNewNamesEveryChangeOnBothPlatforms() {
        for mac in [false, true] {
            let titles = WhatsNew.items(mac: mac).map(\.title)
            XCTAssertEqual(titles.count, 7)
            XCTAssertTrue(titles.contains("Three Places"))
            XCTAssertTrue(titles.contains("Details"))
            XCTAssertTrue(titles.contains("Search or Ask"))
            XCTAssertTrue(titles.contains("Triage"))
            XCTAssertTrue(titles.contains("Today Shows What Is Open"))
            XCTAssertEqual(WhatsNew.places(mac: mac).map(\.symbol).count, 5)
        }
        let phone = WhatsNew.items(mac: false).map(\.text).joined(separator: " ")
        XCTAssertTrue(phone.contains("Chat"), "the Chat tab is named")
        XCTAssertTrue(phone.contains("Swipe"), "the Inbox swipes are named")
        XCTAssertTrue(phone.contains("Move · Later · Done · More"), "the selection bar is named")
        XCTAssertFalse(phone.contains("Bucket") || phone.contains("Project"), "the container is a Bowl")
    }
}
