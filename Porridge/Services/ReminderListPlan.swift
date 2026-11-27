import Foundation

/// A list in Reminders as the sync sees it.
struct ReminderListSnapshot: Equatable {
    /// `calendarIdentifier` (of this device).
    var id: String
    var title: String
    /// The account (`EKSource.sourceIdentifier`).
    var account: String
    /// New reminders can be saved in it (`allowsContentModifications`).
    var isWritable = true
    /// A subscribed or otherwise fixed list.
    var isSubscribed = false
    /// How many reminders are in it, done ones included.
    var reminderCount = 0
    /// Porridge's reminders in it (their URL names an entry), counted by the bowl their to-do is in (or `inbox`).
    var porridgeBowls: [String: Int] = [:]
}

/// A bowl as the sync sees it.
struct ReminderBowlSnapshot: Equatable {
    /// `Projects.key`.
    var key: String
    var name: String
    var isArchived = false
    /// It has at least one open to-do (its list is made only then).
    var hasOpenTodos = false
    /// Shared with me to view only: Porridge always wins.
    var isReadOnly = false
}

/// What this device knows of a bowl's list (`ReminderSyncState`).
struct ReminderLocalList: Codable, Equatable {
    var listID: String
    /// The list's title when the sync last saw or set it.
    var title: String
    /// This device made the list.
    var createdHere: Bool
}

/// Which list belongs to which bowl on this device, what lists to make, rename, join or leave, and when everything
/// stops. Pure: the coordinator (`ReminderSyncEngine`) carries the actions out.
///
/// A bowl's list, when this device does not know it yet, is found (a) by its content: the list where most of
/// Porridge's reminders belong to to-dos of that bowl; (b) by the title the ledger keeps, in the account of the
/// default list; (c) by the bowl's name, only when exactly one list and one bowl have it (trimmed, without case and
/// accents); (d) otherwise it is made, a claim in the ledger first, but only once the bowl has an open to-do, and not
/// while another device's claim is younger than ten minutes. The Inbox's list is always the current default list.
enum ReminderListPlan {
    struct Input {
        var bowls: [ReminderBowlSnapshot]
        var ledger: ReminderListLedger
        var local: [String: ReminderLocalList]
        /// Lists this device left standing after their bowl was deleted: they never become a bowl again.
        var detachedListIDs: Set<String> = []
        var lists: [ReminderListSnapshot]
        var defaultListID: String?
        var device: String
        var now = Date()
        /// `AppContainer.storeError` is set.
        var storeUnavailable = false
        /// "Resume" after a pause over lists that disappeared: go on once (those still gone are unlinked).
        var acceptGoneLists = false
    }

    enum Action: Equatable {
        /// Make the bowl's list (the claim is in the ledger already).
        case create(bowl: String, title: String)
        case rename(listID: String, title: String)
        /// A list made at the same time as another device's (whose claim won): move its reminders into `into`, then
        /// delete it when it is empty.
        case join(bowl: String, from: String, into: String)
        /// The way back (stage 4): a new list becomes a bowl.
        case createBowl(listID: String, title: String)
        /// The way back (stage 3/4): the list was renamed in Reminders.
        case renameBowl(bowl: String, title: String)
    }

    struct Result {
        var pause: ReminderPause?
        /// The list of each bowl that syncs now (and `inbox`).
        var targets: [String: String] = [:]
        /// Bowls whose to-dos do not sync now: archived, unlinked or excluded, linked but not in the store.
        var paused: Set<String> = []
        /// Bowls whose list is not there yet (being made, or another device's claim).
        var waiting: Set<String> = []
        /// Deleted bowls whose list this device knows: after their reminders moved, `afterBowlDeleted`.
        var deletedBowls: [String: String] = [:]
        var actions: [Action] = []
        var ledger: ReminderListLedger
        var local: [String: ReminderLocalList]
        var detachedListIDs: Set<String>
        /// Lists that disappeared (one at a time): their bowls are unlinked.
        var goneLists: [String] = []
    }

    static func plan(_ input: Input) -> Result {
        var result = Result(ledger: input.ledger, local: input.local, detachedListIDs: input.detachedListIDs)
        if input.storeUnavailable {
            result.pause = .storeUnavailable
            return result
        }
        guard !input.lists.isEmpty, let defaultID = input.defaultListID,
              let defaultList = input.lists.first(where: { $0.id == defaultID }) else {
            result.pause = .noAccount
            return result
        }
        if input.bowls.isEmpty, input.ledger.linkedBowlCount > 0 {
            result.pause = .noBowls
            return result
        }
        let account = defaultList.account
        let byID = Dictionary(input.lists.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let bowls = Dictionary(input.bowls.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let now = input.now

        // The Inbox: the default list, whichever it is now.
        result.targets[ReminderMapping.inboxKey] = defaultID
        result.ledger = result.ledger.linking(ReminderMapping.inboxKey, title: defaultList.title, now: now)

        // Lists a bowl may have: writable, not subscribed, in the default list's account, not the default list.
        func isCandidate(_ list: ReminderListSnapshot) -> Bool {
            list.isWritable && !list.isSubscribed && list.account == account && list.id != defaultID
                && !result.detachedListIDs.contains(list.id)
        }
        func taken(_ id: String, except bowl: String) -> Bool {
            result.local.contains { $0.key != bowl && $0.value.listID == id }
        }

        // (a) content, (b) the ledger's title, (c) the bowl's name.
        func find(_ bowl: ReminderBowlSnapshot, title: String?) -> String? {
            let free = input.lists.filter { isCandidate($0) && !taken($0.id, except: bowl.key) }
            let byContent = free.compactMap { list -> (String, Int)? in
                let mine = list.porridgeBowls[bowl.key] ?? 0
                let all = list.porridgeBowls.values.reduce(0, +)
                return mine > 0 && mine * 2 > all ? (list.id, mine) : nil
            }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            if let best = byContent.first, byContent.dropFirst().first?.1 != best.1 { return best.0 }
            if let title {
                let named = free.filter { ReminderMapping.normalized($0.title) == ReminderMapping.normalized(title) }
                if named.count == 1 { return named[0].id }
            }
            let name = ReminderMapping.normalized(bowl.name)
            let sameName = input.bowls.filter { ReminderMapping.normalized($0.name) == name }
            let named = free.filter { ReminderMapping.normalized($0.title) == name }
            if sameName.count == 1, named.count == 1 { return named[0].id }
            return nil
        }

        // Lists known here that disappeared: found again by content or title (an identifier that changed), else gone.
        var gone: [String] = []
        for (key, local) in result.local.sorted(by: { $0.key < $1.key }) where byID[local.listID] == nil {
            if let bowl = bowls[key] {
                guard !bowl.isArchived else { continue }
                result.local[key] = nil
                if let found = find(bowl, title: local.title) {
                    result.local[key] = ReminderLocalList(listID: found, title: byID[found]!.title, createdHere: local.createdHere)
                } else {
                    gone.append(key)
                    result.local[key] = local
                }
            } else if input.ledger.lists[key]?.isTombstone == true {
                // A deleted bowl's list went too: nothing left to clean up.
                result.local[key] = nil
            }
        }
        if gone.count > 1, !input.acceptGoneLists {
            result.pause = .listsGone(gone.count)
            result.local = input.local
            return result
        }
        for key in gone {
            result.local[key] = nil
            result.ledger = result.ledger.unlinking(key, reason: .listGone, now: now)
            result.goneLists.append(key)
            result.paused.insert(key)
        }

        // Deleted bowls: their reminders move to the default list with their to-dos, then the list is cleaned up.
        for (key, local) in result.local where bowls[key] == nil {
            if result.ledger.lists[key]?.isTombstone == true {
                result.deletedBowls[key] = local.listID
            }
            result.paused.insert(key)
        }

        for bowl in input.bowls.sorted(by: { $0.key < $1.key }) where !gone.contains(bowl.key) {
            let key = bowl.key
            let link = result.ledger.lists[key]
            if bowl.isArchived { result.paused.insert(key); continue }
            if link?.state == .excluded || (link?.state == .unlinked && link?.reason == .listGone) {
                result.paused.insert(key)
                continue
            }
            if let local = result.local[key], let list = byID[local.listID] {
                // A list made here at the same time as another device's, whose claim won: join theirs.
                if local.createdHere, let link, link.state == .linked, let device = link.claimDevice, device != input.device,
                   let winner = input.lists.first(where: {
                       $0.id != list.id && isCandidate($0) && !taken($0.id, except: key)
                           && ReminderMapping.normalized($0.title) == ReminderMapping.normalized(link.title ?? bowl.name)
                   }) {
                    result.actions.append(.join(bowl: key, from: list.id, into: winner.id))
                    result.local[key] = ReminderLocalList(listID: winner.id, title: winner.title, createdHere: false)
                    result.targets[key] = winner.id
                    continue
                }
                result.targets[key] = list.id
                // Renamed: on Porridge's side the list follows; renamed in Reminders only, the bowl would (the way
                // back); both: Porridge's name.
                // The title remembered here moves only with what was done: a rename in Reminders that is not taken
                // over stays one (`renameBowl` again next time), it is not overwritten.
                var seen = local.title
                var current = list.title
                if list.title == bowl.name {
                    seen = list.title
                } else if list.title == local.title || bowl.name != local.title || bowl.isReadOnly {
                    result.actions.append(.rename(listID: list.id, title: bowl.name))
                    seen = bowl.name
                    current = bowl.name
                } else {
                    result.actions.append(.renameBowl(bowl: key, title: list.title))
                }
                if seen != local.title { result.local[key]?.title = seen }
                result.ledger = result.ledger.linking(key, title: current, now: now)
                continue
            }
            // Not known here: found, or made once the bowl has an open to-do.
            let isLinked = link?.state == .linked
            guard bowl.hasOpenTodos || isLinked || link?.isTombstone == true else { continue }
            if let found = find(bowl, title: link?.title) {
                let list = byID[found]!
                result.local[key] = ReminderLocalList(listID: found, title: list.title, createdHere: false)
                result.targets[key] = found
                if list.title != bowl.name {
                    result.actions.append(.rename(listID: found, title: bowl.name))
                    result.local[key]?.title = bowl.name
                }
                result.ledger = result.ledger.linking(key, title: bowl.name, now: now)
                continue
            }
            guard bowl.hasOpenTodos else { continue }
            if let link, link.state == .linked, let device = link.claimDevice, device != input.device,
               let claimed = link.claimedAt, now.timeIntervalSince(claimed) < ReminderListLedger.claimWindow {
                // Another device is making it right now.
                result.waiting.insert(key)
                continue
            }
            result.ledger = result.ledger.claiming(key, title: bowl.name, device: input.device, now: now)
            result.actions.append(.create(bowl: key, title: bowl.name))
            result.waiting.insert(key)
        }

        // Linked bowls that are not in the store (not synced yet, or gone without a tombstone): their lists stay.
        for (key, link) in result.ledger.lists where key != ReminderMapping.inboxKey && link.state == .linked && bowls[key] == nil {
            result.paused.insert(key)
        }

        // The way back: lists that belong to no bowl become bowls, unless they are a deleted bowl's, carry a bowl's
        // name, or the ledger knows their title as unlinked.
        let used = Set(result.local.values.map(\.listID))
        let bowlNames = Set(input.bowls.map { ReminderMapping.normalized($0.name) })
        let knownTitles = Set(result.ledger.lists.values.compactMap { $0.title.map(ReminderMapping.normalized) })
        for list in input.lists.sorted(by: { $0.id < $1.id }) where isCandidate(list) && !used.contains(list.id) {
            let name = ReminderMapping.normalized(list.title)
            guard !name.isEmpty, !bowlNames.contains(name), !knownTitles.contains(name) else { continue }
            result.actions.append(.createBowl(listID: list.id, title: list.title))
        }
        return result
    }

    enum Cleanup: Equatable {
        /// Delete the list: empty, made by Porridge, and the bowl's tombstone is there.
        case delete
        /// Leave it standing, no longer linked.
        case detach
    }

    /// A deleted bowl's list once its reminders moved with their to-dos: deleted only when it is empty, Porridge made
    /// it and the bowl's tombstone exists; otherwise left standing.
    static func afterBowlDeleted(remaining: Int, createdByPorridge: Bool, tombstone: Bool) -> Cleanup {
        remaining == 0 && createdByPorridge && tombstone ? .delete : .detach
    }
}
