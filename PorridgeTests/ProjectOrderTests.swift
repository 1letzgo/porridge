import XCTest
@testable import Porridge

/// The order of a bucket's list (`Projects.ordered`), iOS and Mac alike: pinned first, then by last change; the
/// To-dos filter by due day.
@MainActor
final class ProjectOrderTests: XCTestCase {
    private func note(_ title: String, minutesAgo: Double, pinned: Bool = false) -> Note {
        let note = Note()
        note.title = title
        note.updatedAt = Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60)
        note.isPinned = pinned
        return note
    }

    private func todo(_ title: String, minutesAgo: Double, due: String? = nil, done: Bool = false, pinned: Bool = false) -> Note {
        let note = note(title, minutesAgo: minutesAgo, pinned: pinned)
        note.todoState = done ? .done : .open
        if done { note.todoDoneAt = note.updatedAt }
        note.todoDueDay = due
        return note
    }

    func testNewestFirst() {
        let old = note("old", minutesAgo: 30)
        let new = note("new", minutesAgo: 1)
        let middle = note("middle", minutesAgo: 10)
        XCTAssertEqual(Projects.ordered([old, new, middle]).map(\.title), ["new", "middle", "old"])
    }

    func testPinnedFirstThenNewestFirst() {
        let list = [
            note("a", minutesAgo: 1),
            note("pinned old", minutesAgo: 50, pinned: true),
            note("b", minutesAgo: 5),
            note("pinned new", minutesAgo: 20, pinned: true),
        ]
        XCTAssertEqual(Projects.ordered(list).map(\.title), ["pinned new", "pinned old", "a", "b"])
    }

    func testAllMixesKindsAndDoneTodosByLastChange() {
        // The "All" filter: no groups by kind, a done to-do stays where its last change puts it.
        let link = note("link", minutesAgo: 10)
        link.url = "https://example.com"
        let done = todo("done", minutesAgo: 1, done: true)
        let open = todo("open", minutesAgo: 20, due: "2026-11-01")
        let plain = note("plain", minutesAgo: 5)
        XCTAssertEqual(Projects.ordered([open, plain, link, done]).map(\.title), ["done", "plain", "link", "open"])
    }

    func testTodosByDuePinnedFirst() {
        let list = [
            todo("undated new", minutesAgo: 1),
            todo("done", minutesAgo: 0, done: true),
            todo("late", minutesAgo: 40, due: "2026-11-01"),
            todo("soon", minutesAgo: 2, due: "2026-11-25"),
            todo("pinned undated", minutesAgo: 60, pinned: true),
            todo("pinned due", minutesAgo: 90, due: "2026-12-24", pinned: true),
            todo("undated old", minutesAgo: 30),
        ]
        XCTAssertEqual(
            Projects.ordered(list, byDue: true).map(\.title),
            ["pinned due", "pinned undated", "late", "soon", "undated new", "undated old", "done"]
        )
    }
}
