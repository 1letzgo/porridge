import XCTest
@testable import Porridge

/// Which list belongs to which bowl: finding, making, renaming, joining lists, the way back's new bowls, and every
/// brake. Pure, with two devices simulated where it matters.
@MainActor
final class ReminderListPlanTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let inbox = ReminderListSnapshot(id: "L-inbox", title: "Reminders", account: "icloud")

    private func list(_ id: String, _ title: String, account: String = "icloud", porridge: [String: Int] = [:], count: Int = 0) -> ReminderListSnapshot {
        ReminderListSnapshot(id: id, title: title, account: account, reminderCount: count, porridgeBowls: porridge)
    }

    private func bowl(_ key: String, _ name: String, open: Bool = true, archived: Bool = false) -> ReminderBowlSnapshot {
        ReminderBowlSnapshot(key: key, name: name, isArchived: archived, hasOpenTodos: open)
    }

    private func input(
        bowls: [ReminderBowlSnapshot], lists: [ReminderListSnapshot], ledger: ReminderListLedger = .init(),
        local: [String: ReminderLocalList] = [:], device: String = "A", now: Date? = nil
    ) -> ReminderListPlan.Input {
        ReminderListPlan.Input(bowls: bowls, ledger: ledger, local: local, lists: [inbox] + lists, defaultListID: inbox.id, device: device, now: now ?? t0)
    }

    // MARK: Brakes

    func testPausesWithoutStoreAccountOrBowls() {
        var storeDown = input(bowls: [bowl("B1", "Work")], lists: [])
        storeDown.storeUnavailable = true
        XCTAssertEqual(ReminderListPlan.plan(storeDown).pause, .storeUnavailable)

        var noLists = input(bowls: [bowl("B1", "Work")], lists: [])
        noLists.lists = []
        XCTAssertEqual(ReminderListPlan.plan(noLists).pause, .noAccount)
        var noDefault = input(bowls: [bowl("B1", "Work")], lists: [])
        noDefault.defaultListID = nil
        XCTAssertEqual(ReminderListPlan.plan(noDefault).pause, .noAccount)

        // An empty store while the ledger has bowls with lists: nothing is touched.
        let ledger = ReminderListLedger().linking("B1", title: "Work", now: t0)
        XCTAssertEqual(ReminderListPlan.plan(input(bowls: [], lists: [list("L1", "Work")], ledger: ledger)).pause, .noBowls)
        // An empty store and an empty ledger: nothing to do, no pause.
        let empty = ReminderListPlan.plan(input(bowls: [], lists: [list("L1", "Work")]))
        XCTAssertNil(empty.pause)
        XCTAssertEqual(empty.targets, ["inbox": "L-inbox"])
    }

    func testSeveralListsGoneAtOncePauseOneIsUnlinked() {
        let local = [
            "B1": ReminderLocalList(listID: "L1", title: "Work", createdHere: true),
            "B2": ReminderLocalList(listID: "L2", title: "Home", createdHere: true),
        ]
        let ledger = ReminderListLedger().linking("B1", title: "Work", now: t0).linking("B2", title: "Home", now: t0)
        let bowls = [bowl("B1", "Work"), bowl("B2", "Home")]
        let both = ReminderListPlan.plan(input(bowls: bowls, lists: [], ledger: ledger, local: local))
        XCTAssertEqual(both.pause, .listsGone(2))
        XCTAssertEqual(both.local, local)

        // Resumed: both are unlinked, the bowls stay and are not given new lists.
        var resumed = input(bowls: bowls, lists: [], ledger: ledger, local: local)
        resumed.acceptGoneLists = true
        let after = ReminderListPlan.plan(resumed)
        XCTAssertNil(after.pause)
        XCTAssertEqual(after.ledger.lists["B1"]?.reason, .listGone)
        XCTAssertEqual(after.paused, ["B1", "B2"])
        XCTAssertTrue(after.actions.isEmpty)

        // One gone: unlinked, the other syncs on.
        let one = ReminderListPlan.plan(input(bowls: bowls, lists: [list("L2", "Home")], ledger: ledger, local: local))
        XCTAssertNil(one.pause)
        XCTAssertEqual(one.goneLists, ["B1"])
        XCTAssertEqual(one.ledger.lists["B1"]?.state, .unlinked)
        XCTAssertEqual(one.targets["B2"], "L2")
        XCTAssertNil(one.local["B1"])
        // Next time it is not made again.
        let next = ReminderListPlan.plan(input(bowls: bowls, lists: [list("L2", "Home")], ledger: one.ledger, local: one.local))
        XCTAssertFalse(next.actions.contains { if case .create = $0 { true } else { false } })
        XCTAssertTrue(next.paused.contains("B1"))
    }

    func testListWithANewIdentifierIsFoundAgain() {
        let local = ["B1": ReminderLocalList(listID: "L1-old", title: "Work", createdHere: true)]
        let result = ReminderListPlan.plan(input(bowls: [bowl("B1", "Work")], lists: [list("L1-new", "Work")], local: local))
        XCTAssertNil(result.pause)
        XCTAssertEqual(result.targets["B1"], "L1-new")
        XCTAssertTrue(result.goneLists.isEmpty)
    }

    // MARK: Finding and making

    func testListIsMadeOnlyForABowlWithAnOpenTodo() {
        let none = ReminderListPlan.plan(input(bowls: [bowl("B1", "Work", open: false)], lists: []))
        XCTAssertTrue(none.actions.isEmpty)
        let made = ReminderListPlan.plan(input(bowls: [bowl("B1", "Work")], lists: []))
        XCTAssertEqual(made.actions, [.create(bowl: "B1", title: "Work")])
        XCTAssertEqual(made.ledger.lists["B1"]?.claimDevice, "A")
        XCTAssertEqual(made.ledger.lists["B1"]?.createdByPorridge, true)
        XCTAssertTrue(made.waiting.contains("B1"))
    }

    func testFoundByContentThenTitleThenName() {
        // (a) Content: the list where most of Porridge's reminders belong to the bowl, whatever its title.
        let content = ReminderListPlan.plan(input(bowls: [bowl("B1", "Work")], lists: [list("L1", "Job", porridge: ["B1": 3, "inbox": 1]), list("L2", "Work")]))
        XCTAssertEqual(content.targets["B1"], "L1")
        XCTAssertEqual(content.actions, [.rename(listID: "L1", title: "Work")])

        // (b) The ledger's title (the bowl was renamed on another device that made the list).
        let ledger = ReminderListLedger().claiming("B1", title: "Office", device: "B", now: t0.addingTimeInterval(-3600))
        let titled = ReminderListPlan.plan(input(bowls: [bowl("B1", "Work")], lists: [list("L1", "Office")], ledger: ledger))
        XCTAssertEqual(titled.targets["B1"], "L1")
        XCTAssertEqual(titled.local["B1"]?.createdHere, false)

        // (c) The bowl's name, without case and accents.
        let named = ReminderListPlan.plan(input(bowls: [bowl("B1", "Café")], lists: [list("L1", " cafe ")]))
        XCTAssertEqual(named.targets["B1"], "L1")

        // Not when two bowls or two lists have the name, nor in another account.
        let twoBowls = ReminderListPlan.plan(input(bowls: [bowl("B1", "Work"), bowl("B2", "work")], lists: [list("L1", "Work")]))
        XCTAssertNil(twoBowls.targets["B1"])
        let twoLists = ReminderListPlan.plan(input(bowls: [bowl("B1", "Work")], lists: [list("L1", "Work"), list("L2", "WORK")]))
        XCTAssertEqual(twoLists.actions.first, .create(bowl: "B1", title: "Work"))
        let otherAccount = ReminderListPlan.plan(input(bowls: [bowl("B1", "Work")], lists: [list("L1", "Work", account: "exchange")]))
        XCTAssertEqual(otherAccount.actions.first, .create(bowl: "B1", title: "Work"))
    }

    func testDefaultListIsNeverABowlsList() {
        let result = ReminderListPlan.plan(input(bowls: [bowl("B1", "Reminders")], lists: []))
        XCTAssertEqual(result.actions.first, .create(bowl: "B1", title: "Reminders"))
        XCTAssertEqual(result.targets["inbox"], "L-inbox")
        XCTAssertEqual(result.ledger.lists["inbox"]?.title, "Reminders")
    }

    func testWaitsWhileAnotherDeviceMakesTheList() {
        let ledger = ReminderListLedger().claiming("B1", title: "Work", device: "B", now: t0.addingTimeInterval(-60))
        let waiting = ReminderListPlan.plan(input(bowls: [bowl("B1", "Work")], lists: [], ledger: ledger))
        XCTAssertTrue(waiting.actions.isEmpty)
        XCTAssertTrue(waiting.waiting.contains("B1"))
        // Its claim is old and the list never came: made here.
        let later = ReminderListPlan.plan(input(bowls: [bowl("B1", "Work")], lists: [], ledger: ledger, now: t0.addingTimeInterval(11 * 60)))
        XCTAssertEqual(later.actions, [.create(bowl: "B1", title: "Work")])
    }

    func testTwoDevicesMakeTheListAtTheSameTimeAndJoin() {
        let bowls = [bowl("B1", "Work")]
        // Both make one before they see each other's claim.
        let a = ReminderListPlan.plan(input(bowls: bowls, lists: [], device: "A", now: t0))
        let b = ReminderListPlan.plan(input(bowls: bowls, lists: [], device: "B", now: t0.addingTimeInterval(20)))
        XCTAssertEqual(a.actions, [.create(bowl: "B1", title: "Work")])
        XCTAssertEqual(b.actions, [.create(bowl: "B1", title: "Work")])
        var localA = a.local, localB = b.local
        localA["B1"] = ReminderLocalList(listID: "LA", title: "Work", createdHere: true)
        localB["B1"] = ReminderLocalList(listID: "LB", title: "Work", createdHere: true)
        let lists = [list("LA", "Work"), list("LB", "Work")]

        // The ledgers meet: A's earlier claim wins on both devices.
        let ledger = ReminderListLedger.merged(a.ledger, b.ledger)
        XCTAssertEqual(ledger, ReminderListLedger.merged(b.ledger, a.ledger))
        XCTAssertEqual(ledger.lists["B1"]?.claimDevice, "A")

        let nextA = ReminderListPlan.plan(input(bowls: bowls, lists: lists, ledger: ledger, local: localA, device: "A", now: t0.addingTimeInterval(60)))
        XCTAssertEqual(nextA.targets["B1"], "LA")
        XCTAssertFalse(nextA.actions.contains { if case .join = $0 { true } else { false } })

        let nextB = ReminderListPlan.plan(input(bowls: bowls, lists: lists, ledger: ledger, local: localB, device: "B", now: t0.addingTimeInterval(60)))
        XCTAssertEqual(nextB.actions, [.join(bowl: "B1", from: "LB", into: "LA")])
        XCTAssertEqual(nextB.targets["B1"], "LA")
        XCTAssertEqual(nextB.local["B1"], ReminderLocalList(listID: "LA", title: "Work", createdHere: false))

        // B's list deleted after the join: B keeps A's list, nothing is gone.
        let settled = ReminderListPlan.plan(input(bowls: bowls, lists: [list("LA", "Work")], ledger: ledger, local: nextB.local, device: "B", now: t0.addingTimeInterval(120)))
        XCTAssertNil(settled.pause)
        XCTAssertEqual(settled.targets["B1"], "LA")
        XCTAssertTrue(settled.actions.isEmpty)
    }

    func testJoinWaitsUntilTheWinnersListIsHere() {
        let ledger = ReminderListLedger().claiming("B1", title: "Work", device: "A", now: t0)
        let local = ["B1": ReminderLocalList(listID: "LB", title: "Work", createdHere: true)]
        let result = ReminderListPlan.plan(input(bowls: [bowl("B1", "Work")], lists: [list("LB", "Work")], ledger: ledger, local: local, device: "B"))
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertEqual(result.targets["B1"], "LB")
    }

    // MARK: Renaming

    func testRenamingFollowsPorridgeAndOffersTheWayBack() {
        let local = ["B1": ReminderLocalList(listID: "L1", title: "Work", createdHere: true)]
        // Renamed in Porridge: the list follows.
        let renamed = ReminderListPlan.plan(input(bowls: [bowl("B1", "Office")], lists: [list("L1", "Work")], local: local))
        XCTAssertEqual(renamed.actions, [.rename(listID: "L1", title: "Office")])
        XCTAssertEqual(renamed.local["B1"]?.title, "Office")
        XCTAssertEqual(renamed.ledger.lists["B1"]?.title, "Office")
        // Renamed in Reminders only: the bowl would follow (the way back); the title remembered here stays.
        let theirs = ReminderListPlan.plan(input(bowls: [bowl("B1", "Work")], lists: [list("L1", "Job")], local: local))
        XCTAssertEqual(theirs.actions, [.renameBowl(bowl: "B1", title: "Job")])
        XCTAssertEqual(theirs.local["B1"]?.title, "Work")
        // Both: Porridge's name.
        let both = ReminderListPlan.plan(input(bowls: [bowl("B1", "Office")], lists: [list("L1", "Job")], local: local))
        XCTAssertEqual(both.actions, [.rename(listID: "L1", title: "Office")])
        // Viewing only: Porridge's name.
        var readOnly = bowl("B1", "Work")
        readOnly.isReadOnly = true
        let shared = ReminderListPlan.plan(input(bowls: [readOnly], lists: [list("L1", "Job")], local: local))
        XCTAssertEqual(shared.actions, [.rename(listID: "L1", title: "Work")])
    }

    // MARK: Archive and deletion

    func testArchivedBowlKeepsItsListUntouched() {
        let local = ["B1": ReminderLocalList(listID: "L1", title: "Work", createdHere: true)]
        let result = ReminderListPlan.plan(input(bowls: [bowl("B1", "Office", archived: true)], lists: [list("L1", "Work")], local: local))
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertTrue(result.paused.contains("B1"))
        XCTAssertNil(result.targets["B1"])
        XCTAssertEqual(result.local, local)
        // Its list gone while archived: noticed only once it is back.
        let gone = ReminderListPlan.plan(input(bowls: [bowl("B1", "Work", archived: true)], lists: [], local: local))
        XCTAssertTrue(gone.goneLists.isEmpty)
        XCTAssertEqual(gone.local, local)
    }

    func testDeletedBowlsListIsCleanedUpOnlyWithItsTombstone() {
        let local = ["B1": ReminderLocalList(listID: "L1", title: "Work", createdHere: true)]
        let tomb = ReminderListLedger().claiming("B1", title: "Work", device: "A", now: t0).unlinking("B1", reason: .bowlDeleted, now: t0)
        let deleted = ReminderListPlan.plan(input(bowls: [bowl("B2", "Home")], lists: [list("L1", "Work")], ledger: tomb, local: local))
        XCTAssertEqual(deleted.deletedBowls, ["B1": "L1"])
        XCTAssertTrue(deleted.paused.contains("B1"))
        // Its list never becomes a bowl again.
        XCTAssertFalse(deleted.actions.contains { if case .createBowl = $0 { true } else { false } })

        // Missing without a tombstone (not synced yet, or a store that lost it): the list stays, nothing is cleaned up.
        let linked = ReminderListLedger().linking("B1", title: "Work", now: t0)
        let missing = ReminderListPlan.plan(input(bowls: [bowl("B2", "Home")], lists: [list("L1", "Work")], ledger: linked, local: local))
        XCTAssertTrue(missing.deletedBowls.isEmpty)
        XCTAssertTrue(missing.paused.contains("B1"))
        XCTAssertEqual(missing.local, local)

        XCTAssertEqual(ReminderListPlan.afterBowlDeleted(remaining: 0, createdByPorridge: true, tombstone: true), .delete)
        XCTAssertEqual(ReminderListPlan.afterBowlDeleted(remaining: 1, createdByPorridge: true, tombstone: true), .detach)
        XCTAssertEqual(ReminderListPlan.afterBowlDeleted(remaining: 0, createdByPorridge: false, tombstone: true), .detach)
        XCTAssertEqual(ReminderListPlan.afterBowlDeleted(remaining: 0, createdByPorridge: true, tombstone: false), .detach)
    }

    // MARK: The way back: new lists become bowls

    func testNewWritableListOfTheAccountBecomesABowl() {
        var subscribed = list("L3", "Holidays")
        subscribed.isSubscribed = true
        var readOnly = list("L4", "Team")
        readOnly.isWritable = false
        let lists = [list("L1", "Garden"), list("L2", "Work"), subscribed, readOnly, list("L5", "Exchange", account: "work"), list("L6", "Old")]
        var plan = input(bowls: [bowl("B1", "Work", open: false)], lists: lists)
        plan.detachedListIDs = ["L6"]
        let result = ReminderListPlan.plan(plan)
        XCTAssertEqual(result.actions.filter { if case .createBowl = $0 { true } else { false } }, [.createBowl(listID: "L1", title: "Garden")])

        // A deleted bowl's list (known by its title in the ledger) does not either.
        let tomb = ReminderListLedger().linking("B9", title: "Garden", now: t0).unlinking("B9", reason: .bowlDeleted, now: t0)
        let none = ReminderListPlan.plan(input(bowls: [bowl("B1", "Work", open: false)], lists: [list("L1", "Garden")], ledger: tomb))
        XCTAssertFalse(none.actions.contains { if case .createBowl = $0 { true } else { false } })
    }
}
