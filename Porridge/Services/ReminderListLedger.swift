import Foundation

/// Which list in Reminders belongs to which bowl, across the user's devices (the sync with Reminders: one list = one
/// bowl). Kept in iCloud key-value storage (`ReminderLists`), not in CloudKit records, as `AppointmentLedger`: by the
/// bowl's key (`Projects.key`), or `inbox` for the to-dos in no bowl (they go into the default list of Reminders).
/// Lists have no identifier that is the same on every device: a device finds a bowl's list by its content, by the
/// title kept here, or by the bowl's name (`ReminderListPlan`). Entry by entry the later change wins; two devices that
/// both set out to make a bowl's list at the same time settle on the earlier claim.
struct ReminderListLedger: Codable, Equatable {
    struct Link: Codable, Equatable {
        enum State: String, Codable {
            /// The bowl has a list (or is about to get one: a claim).
            case linked
            /// The bowl does not take part.
            case excluded
            /// The link was cut, the list left standing: a tombstone (`reason`).
            case unlinked
        }

        enum Reason: String, Codable {
            /// The bowl was deleted (or a shared bowl left): its list never becomes a bowl again.
            case bowlDeleted
            /// The list disappeared from Reminders: the bowl stays, without a list.
            case listGone
        }

        var state: State
        /// The list's title as last known.
        var title: String?
        /// Porridge made the list (not an existing list taken on by its name).
        var createdByPorridge: Bool = false
        /// When a device set out to make the list, and which one.
        var claimedAt: Date?
        var claimDevice: String?
        var reason: Reason?
        var changedAt: Date

        var isTombstone: Bool { state == .unlinked && reason == .bowlDeleted }
    }

    var lists: [String: Link] = [:]

    /// Two claims less than this apart were made at the same time: the earlier one wins. A claim this old that has
    /// not brought a list to a device yet no longer holds it back.
    static let claimWindow: TimeInterval = 10 * 60
    /// Unlinked entries are kept this long, so a deleted bowl's list does not become a bowl again.
    static let keepTombstones: TimeInterval = 365 * 86400

    // MARK: Merging

    /// Entry by entry the later change wins; two claims of different devices made within `claimWindow` of each
    /// other: the earlier claim wins (the same moment: the smaller device id). The same on every device whatever the
    /// order of the sides.
    static func merged(_ a: ReminderListLedger?, _ b: ReminderListLedger?) -> ReminderListLedger {
        guard let a else { return b ?? ReminderListLedger() }
        guard let b else { return a }
        var result = a
        for (key, theirs) in b.lists {
            guard let mine = result.lists[key] else {
                result.lists[key] = theirs
                continue
            }
            result.lists[key] = winner(mine, theirs)
        }
        return result
    }

    static func winner(_ a: Link, _ b: Link) -> Link {
        if a == b { return a }
        if a.state == .linked, b.state == .linked, let ca = a.claimedAt, let cb = b.claimedAt,
           let da = a.claimDevice, let db = b.claimDevice, da != db, abs(ca.timeIntervalSince(cb)) < claimWindow {
            return (ca, da) < (cb, db) ? a : b
        }
        if a.changedAt != b.changedAt { return a.changedAt > b.changedAt ? a : b }
        // The same moment: a fixed order, so both devices keep the same.
        return order(a) <= order(b) ? a : b
    }

    private static func order(_ link: Link) -> String {
        [link.state.rawValue, link.reason?.rawValue ?? "", link.claimDevice ?? "", link.title ?? ""].joined(separator: "|")
    }

    /// Without unlinked entries older than `keepTombstones`.
    func pruned(now: Date = Date()) -> ReminderListLedger {
        var result = self
        let cutoff = now.addingTimeInterval(-Self.keepTombstones)
        result.lists = lists.filter { $0.value.state != .unlinked || $0.value.changedAt > cutoff }
        return result
    }

    // MARK: Changes

    /// This device sets out to make the bowl's list: its claim, before the list is made.
    func claiming(_ key: String, title: String, device: String, now: Date = Date()) -> ReminderListLedger {
        var result = self
        result.lists[key] = Link(state: .linked, title: title, createdByPorridge: true, claimedAt: now, claimDevice: device, changedAt: now)
        return result
    }

    /// The bowl's list was found (taken on): linked, keeping a claim that is there.
    func linking(_ key: String, title: String, createdByPorridge: Bool? = nil, now: Date = Date()) -> ReminderListLedger {
        var result = self
        var link = lists[key].flatMap { $0.state == .linked ? $0 : nil }
            ?? Link(state: .linked, title: title, createdByPorridge: createdByPorridge ?? false, changedAt: now)
        guard link.title != title || lists[key]?.state != .linked || (createdByPorridge.map { $0 != link.createdByPorridge } ?? false) else {
            return self
        }
        link.title = title
        if let createdByPorridge { link.createdByPorridge = createdByPorridge }
        link.reason = nil
        link.changedAt = now
        result.lists[key] = link
        return result
    }

    /// The link is cut, the list stays: `bowlDeleted` (a tombstone) or `listGone`. Nothing without an entry.
    func unlinking(_ key: String, reason: Link.Reason, now: Date = Date()) -> ReminderListLedger {
        guard var link = lists[key], !(link.state == .unlinked && link.reason == reason) else { return self }
        link.state = .unlinked
        link.reason = reason
        link.changedAt = now
        var result = self
        result.lists[key] = link
        return result
    }

    /// The bowls whose list disappeared take part again (the sync turned on anew): linked without a list, so the
    /// next run finds or makes one. Written as a change, so other devices do not bring the old entry back.
    func revivingGoneLists(now: Date = Date()) -> ReminderListLedger {
        var result = self
        for (key, link) in lists where link.state == .unlinked && link.reason == .listGone {
            result.lists[key] = Link(state: .linked, title: link.title, createdByPorridge: false, changedAt: now)
        }
        return result
    }

    /// Bowls linked to a list (the Inbox not counted).
    var linkedBowlCount: Int {
        lists.filter { $0.key != ReminderMapping.inboxKey && $0.value.state == .linked }.count
    }
}
