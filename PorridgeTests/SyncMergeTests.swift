import XCTest
@testable import Porridge

/// The same cases as Android's `SyncMergeTest`: both platforms have to merge alike.
final class SyncMergeTests: XCTestCase {
    private func rec(_ id: String, _ text: String, _ updatedAt: Int64) -> SyncRecord {
        ["id": id, "text": text, "updatedAt": NSNumber(value: updatedAt)]
    }

    private func local(_ r: SyncRecord) -> SyncMerge.Local {
        SyncMerge.Local(record: r, updatedAt: SyncMerge.int64(r["updatedAt"]))
    }

    private func base(_ r: SyncRecord) -> SyncBase {
        SyncBase(local: SyncMerge.hash(r), remote: SyncMerge.hash(r))
    }

    private func text(_ record: SyncRecord?) -> String? {
        record?["text"] as? String
    }

    func testDamagedFileIsRefusedInsteadOfReadAsEmpty() throws {
        for text in ["", "<html>Bad Gateway</html>", "{\"notes\": [{\"id\"", "[]", "{\"deleted\": []}", "{\"notes\": {}}"] {
            XCTAssertThrowsError(try SyncMerge.parseFile(Data(text.utf8)), text)
        }
        let file = try SyncMerge.parseFile(Data("{\"version\": 1, \"notes\": [], \"deleted\": {\"notes\": {\"A\": 5}}}".utf8))
        XCTAssertEqual(Set(file.keys), ["version", "notes", "deleted"])
    }

    func testARecordWithoutBaseIsNotReadAsDeleted() {
        let result = SyncMerge.merge(local: [:], remote: ["A": rec("A", "x", 1)], tombstones: [:], base: [:], now: 10)
        XCTAssertEqual(Set(result.toApply.keys), ["A"])
        XCTAssertEqual(Set(result.merged.keys), ["A"])
        XCTAssertTrue(result.tombstones.isEmpty)
    }

    func testNewOnEitherSideIsKept() {
        let result = SyncMerge.merge(
            local: ["A": local(rec("A", "here", 1))], remote: ["B": rec("B", "there", 1)], tombstones: [:], base: [:], now: 10)
        XCTAssertEqual(Set(result.merged.keys), ["A", "B"])
        XCTAssertEqual(Set(result.toApply.keys), ["B"])
    }

    func testTheSideThatChangedWins() {
        let old = rec("A", "old", 1)
        // Changed elsewhere only.
        var result = SyncMerge.merge(
            local: ["A": local(old)], remote: ["A": rec("A", "edited", 2)], tombstones: [:], base: ["A": base(old)], now: 10)
        XCTAssertEqual(text(result.merged["A"]), "edited")
        XCTAssertEqual(Set(result.toApply.keys), ["A"])
        // Changed here only, even with an older time stamp.
        result = SyncMerge.merge(
            local: ["A": local(rec("A", "here", 0))], remote: ["A": old], tombstones: [:], base: ["A": base(old)], now: 10)
        XCTAssertEqual(text(result.merged["A"]), "here")
        XCTAssertTrue(result.toApply.isEmpty)
    }

    func testBothChangedTheNewerWins() {
        let result = SyncMerge.merge(
            local: ["A": local(rec("A", "here", 5))], remote: ["A": rec("A", "there", 7)], tombstones: [:],
            base: ["A": base(rec("A", "old", 1))], now: 10)
        XCTAssertEqual(text(result.merged["A"]), "there")
    }

    /// What an edit during a sync relies on: the base holds the state before it, so the edit counts as a change.
    func testAnEditAfterTheBaseWasTakenGoesUp() {
        let old = rec("A", "old", 1)
        let result = SyncMerge.merge(
            local: ["A": local(rec("A", "edited during the upload", 2))], remote: ["A": old], tombstones: [:],
            base: ["A": base(old)], now: 10)
        XCTAssertEqual(text(result.merged["A"]), "edited during the upload")
        XCTAssertTrue(result.toApply.isEmpty)
    }

    func testDeletionsTravelAsTombstones() {
        let a = rec("A", "x", 1)
        // Deleted here: the file gets a tombstone.
        var result = SyncMerge.merge(local: [:], remote: ["A": a], tombstones: [:], base: ["A": base(a)], now: 10)
        XCTAssertNil(result.merged["A"])
        XCTAssertEqual(result.tombstones["A"], 10)
        // The other device learns it and deletes.
        result = SyncMerge.merge(local: ["A": local(a)], remote: [:], tombstones: ["A": 10], base: ["A": base(a)], now: 20)
        XCTAssertEqual(result.toDelete, ["A"])
        // An edit after the deletion brings it back.
        result = SyncMerge.merge(
            local: ["A": local(rec("A", "again", 15))], remote: [:], tombstones: ["A": 10], base: ["A": base(a)], now: 20)
        XCTAssertTrue(result.toDelete.isEmpty)
        XCTAssertNotNil(result.merged["A"])
        XCTAssertNil(result.tombstones["A"])
    }

    func testFrozenRecordsStayAsTheyAre() {
        let result = SyncMerge.merge(
            local: ["A": local(rec("A", "processing", 5))], remote: [:], tombstones: [:], base: [:], frozen: ["A"], now: 10)
        XCTAssertTrue(result.merged.isEmpty && result.toApply.isEmpty && result.toDelete.isEmpty)
    }

    /// Two devices with a shared file end up with the same records, whatever each did.
    func testTwoDevicesConverge() {
        final class Device {
            var store: [String: SyncRecord] = [:]
            var base: [String: SyncBase] = [:]
        }
        var file: [String: SyncRecord] = [:]
        var stones: [String: Int64] = [:]
        var clock: Int64 = 0
        func sync(_ d: Device) {
            clock += 1
            let result = SyncMerge.merge(local: d.store.mapValues(local), remote: file, tombstones: stones, base: d.base, now: clock)
            d.store.merge(result.toApply) { _, new in new }
            result.toDelete.forEach { d.store[$0] = nil }
            file = result.merged
            stones = result.tombstones
            d.base = result.merged.reduce(into: [:]) { base, entry in
                base[entry.key] = SyncBase(local: d.store[entry.key].map(SyncMerge.hash) ?? "", remote: SyncMerge.hash(entry.value))
            }
        }
        func same(_ a: Device, _ b: Device) {
            XCTAssertEqual(a.store.mapValues(SyncMerge.hash), b.store.mapValues(SyncMerge.hash))
        }
        let phone = Device(), mac = Device()
        phone.store["1"] = rec("1", "one", 1)
        phone.store["2"] = rec("2", "two", 1)
        sync(phone); sync(mac)
        same(phone, mac)
        mac.store["1"] = rec("1", "one from mac", 3)
        phone.store["2"] = nil
        phone.store["3"] = rec("3", "three", 4)
        sync(phone); sync(mac); sync(phone)
        same(phone, mac)
        XCTAssertEqual(Set(mac.store.keys), ["1", "3"])
        XCTAssertEqual(text(phone.store["1"]), "one from mac")
    }

    func testHashIgnoresKeyOrder() {
        XCTAssertEqual(SyncMerge.hash(["b": 1, "a": "x"]), SyncMerge.hash(["a": "x", "b": 1]))
    }

    func testNameFollowsTheUser() {
        typealias S = SyncMerge.Setting
        // First run: the name in the file comes to the device; the other platform's stays in the file.
        let first = SyncMerge.mergeSettings(
            local: ["myName": "", "myVoiceAndroid": ""],
            remote: ["myName": S(value: "Daniel", updatedAt: 5), "myVoiceApple": S(value: "V1", updatedAt: 5)],
            base: [:], now: 10)
        XCTAssertEqual(first.toApply, ["myName": "Daniel"])
        XCTAssertEqual(first.file["myVoiceApple"], S(value: "V1", updatedAt: 5))
        XCTAssertEqual(first.base["myName"], "Daniel")

        // Changed on the device: the device wins and writes with its time.
        let changed = SyncMerge.mergeSettings(
            local: ["myName": "Dan"], remote: ["myName": S(value: "Daniel", updatedAt: 5)], base: ["myName": "Daniel"], now: 20)
        XCTAssertTrue(changed.toApply.isEmpty)
        XCTAssertEqual(changed.file["myName"], S(value: "Dan", updatedAt: 20))

        // Changed elsewhere, not here: the file wins.
        let elsewhere = SyncMerge.mergeSettings(
            local: ["myName": "Daniel"], remote: ["myName": S(value: "Dan", updatedAt: 30)], base: ["myName": "Daniel"], now: 40)
        XCTAssertEqual(elsewhere.toApply, ["myName": "Dan"])

        // First run, only the device has a name: it goes into the file.
        let push = SyncMerge.mergeSettings(local: ["myName": "Anna"], remote: [:], base: [:], now: 50)
        XCTAssertEqual(push.file["myName"], S(value: "Anna", updatedAt: 50))

        // Nothing set anywhere: the file stays without an entry.
        XCTAssertTrue(SyncMerge.mergeSettings(local: ["myName": ""], remote: [:], base: [:], now: 60).file.isEmpty)
    }
}
