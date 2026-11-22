import Foundation
import Observation

/// One quiet hint a day, shown in the app (never as a notification): "12 entries in the Inbox", "Yesterday's
/// meeting has 3 possible to-dos". It is worked out on the device from the entries. At most one hint a day across
/// the person's devices (the ledger syncs through iCloud key-value storage where the app has the entitlement: the
/// iPhone and iPad; the Mac keeps its ledger locally until its entitlements get the key-value store too). A hint that is
/// ignored day after day goes to sleep; one that is closed leaves its kind alone for a few days. Off in Settings.
struct DailyHint: Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case inbox, meetingTodos, overdue
    }

    var kind: Kind
    var message: String
    var systemImage: String
    /// The meeting a "possible to-dos" hint is about; opened from the hint.
    var noteID: UUID?

    /// The same hint on another device and on another refresh of the day.
    var id: String { kind.rawValue + (noteID.map { ":" + $0.uuidString } ?? "") }

    static let enabledKey = "dailyHintEnabled"
    static let ledgerKey = "dailyHintLedger"

    /// An Inbox shorter than this is no reason for a hint.
    static let inboxThreshold = 10
    /// Shown this many days in a row without being touched, the hints sleep.
    static let ignoredLimit = 3
    static let sleepDays = 7
    /// A closed hint leaves its kind alone this long.
    static let closedKindDays = 3

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    // MARK: Candidates

    /// The hints the entries give today, the most useful first. Pure: tested without a store.
    static func candidates(notes: [Note], now: Date = Date(), calendar: Calendar = .current) -> [DailyHint] {
        let living = notes.filter { !$0.isDeleted }
        var hints: [DailyHint] = []
        // Yesterday's meetings with tasks still waiting to become to-dos.
        let today = calendar.startOfDay(for: now)
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
            let made = Dictionary(grouping: living.filter { $0.todoSourceID != nil }, by: { $0.todoSourceID ?? "" })
            let meetings = living
                .filter { $0.isRecording && $0.createdAt >= yesterday && $0.createdAt < today }
                .map { ($0, $0.pendingTodoSuggestions(made: made[$0.id.uuidString] ?? []).count) }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
            if let (meeting, count) = meetings.first {
                hints.append(DailyHint(
                    kind: .meetingTodos,
                    message: count == 1
                        ? String(localized: "Yesterday's meeting “\(meeting.displayTitle)” has 1 possible to-do")
                        : String(localized: "Yesterday's meeting “\(meeting.displayTitle)” has \(count) possible to-dos"),
                    systemImage: "checklist", noteID: meeting.id
                ))
            }
        }
        let overdue = living.filter { $0.isTodo && !$0.isDone && $0.todoDue.flatMap { Todos.dueStatus($0, now: now, calendar: calendar) } == .overdue }.count
        if overdue > 0 {
            hints.append(DailyHint(
                kind: .overdue,
                message: overdue == 1 ? String(localized: "1 to-do is overdue") : String(localized: "\(overdue) to-dos are overdue"),
                systemImage: "calendar.badge.exclamationmark"
            ))
        }
        let inbox = living.filter(\.isInInbox).count
        if inbox >= inboxThreshold {
            hints.append(DailyHint(kind: .inbox, message: String(localized: "\(inbox) entries in the Inbox"), systemImage: "tray"))
        }
        return hints
    }
}

/// What happened with the hints: the day one was shown (on any device), whether it was touched, how often they were
/// ignored, and how long they sleep. Days are "yyyy-MM-dd" in the device's calendar.
struct HintLedger: Codable, Equatable {
    /// The day a hint was last shown, and which.
    var day: String?
    var hintID: String?
    /// The hint of `day` was opened or closed.
    var touched = false
    /// Days in a row a hint was shown and left alone.
    var ignoredStreak = 0
    /// No hint before this day.
    var sleepsUntil: String?
    /// A kind closed by hand: not again before this day.
    var kindSleepsUntil: [String: String] = [:]

    /// The hint to show today, and the ledger after showing it. Nil when none may show: today's hint was another
    /// one (shown on another device), it was closed today, or the hints sleep.
    static func choose(_ candidates: [DailyHint], ledger: HintLedger, today: String) -> (hint: DailyHint?, ledger: HintLedger) {
        var ledger = ledger
        // Today's hint is decided: the same one may show again (another device, another refresh); nothing else.
        if ledger.day == today {
            guard !ledger.touched, let id = ledger.hintID, let same = candidates.first(where: { $0.id == id }) else { return (nil, ledger) }
            return (same, ledger)
        }
        // A new day: yesterday's hint left alone counts as ignored.
        if ledger.day != nil {
            ledger.ignoredStreak = ledger.touched ? 0 : ledger.ignoredStreak + 1
            ledger.touched = false
            ledger.day = nil
            ledger.hintID = nil
            if ledger.ignoredStreak >= DailyHint.ignoredLimit {
                ledger.sleepsUntil = HintLedger.day(today, plus: DailyHint.sleepDays)
                ledger.ignoredStreak = 0
            }
        }
        if let until = ledger.sleepsUntil {
            if today < until { return (nil, ledger) }
            ledger.sleepsUntil = nil
        }
        ledger.kindSleepsUntil = ledger.kindSleepsUntil.filter { today < $0.value }
        guard let hint = candidates.first(where: { ledger.kindSleepsUntil[$0.kind.rawValue] == nil }) else { return (nil, ledger) }
        ledger.day = today
        ledger.hintID = hint.id
        ledger.touched = false
        return (hint, ledger)
    }

    /// The hint was opened: it was useful, the streak starts again.
    func opened(today: String) -> HintLedger {
        var ledger = self
        guard ledger.day == today else { return ledger }
        ledger.touched = true
        ledger.ignoredStreak = 0
        return ledger
    }

    /// The hint was closed: gone for today, its kind for a few days.
    func closed(_ hint: DailyHint, today: String) -> HintLedger {
        var ledger = self
        ledger.day = today
        ledger.hintID = hint.id
        ledger.touched = true
        ledger.ignoredStreak = 0
        ledger.kindSleepsUntil[hint.kind.rawValue] = HintLedger.day(today, plus: DailyHint.closedKindDays)
        return ledger
    }

    /// Of two ledgers (this device's and the synced one) the one that knows the later day.
    static func newer(_ a: HintLedger?, _ b: HintLedger?) -> HintLedger {
        switch (a, b) {
        case let (a?, b?):
            guard a.day == b.day else { return (a.day ?? "") > (b.day ?? "") ? a : b }
            // The same day on both: closed or opened on either counts, and every sleep is kept.
            var merged = a
            merged.touched = a.touched || b.touched
            merged.ignoredStreak = max(a.ignoredStreak, b.ignoredStreak)
            merged.sleepsUntil = [a.sleepsUntil, b.sleepsUntil].compactMap { $0 }.max()
            merged.kindSleepsUntil = a.kindSleepsUntil.merging(b.kindSleepsUntil) { max($0, $1) }
            return merged
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return HintLedger()
        }
    }

    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func day(_ key: String, plus days: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let later = calendar.date(byAdding: .day, value: days, to: date) else { return key }
        return HintLedger.key(for: later, calendar: calendar)
    }
}

/// The hint of the day for the views (iOS Inbox, Mac list header): reads and writes the ledger, here and in iCloud.
@MainActor
@Observable
final class DailyHints {
    static let shared = DailyHints()

    private(set) var current: DailyHint?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cloud: NSUbiquitousKeyValueStore?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, cloud: NSUbiquitousKeyValueStore? = .default) {
        self.defaults = defaults
        self.cloud = cloud
        if let cloud {
            observer = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main
            ) { [weak self] _ in
                // Another device showed or closed today's hint: this one follows at its next refresh.
                MainActor.assumeIsolated { self?.followCloud() }
            }
            cloud.synchronize()
        }
    }

    private var ledger: HintLedger {
        get {
            let decode: (Data?) -> HintLedger? = { $0.flatMap { try? JSONDecoder().decode(HintLedger.self, from: $0) } }
            return HintLedger.newer(decode(defaults.data(forKey: DailyHint.ledgerKey)), decode(cloud?.data(forKey: DailyHint.ledgerKey)))
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: DailyHint.ledgerKey)
            cloud?.set(data, forKey: DailyHint.ledgerKey)
        }
    }

    /// Works out today's hint from the entries. Cheap; call when the list changes or the app comes forward.
    func refresh(notes: [Note], now: Date = Date()) {
        guard DailyHint.isEnabled else {
            current = nil
            return
        }
        let today = HintLedger.key(for: now)
        let (hint, next) = HintLedger.choose(DailyHint.candidates(notes: notes, now: now), ledger: ledger, today: today)
        if next != ledger { ledger = next }
        if hint != current { current = hint }
    }

    func open() {
        ledger = ledger.opened(today: HintLedger.key(for: Date()))
        current = nil
    }

    func close() {
        guard let hint = current else { return }
        ledger = ledger.closed(hint, today: HintLedger.key(for: Date()))
        current = nil
    }

    private func followCloud() {
        let ledger = self.ledger
        if let current, ledger.day == HintLedger.key(for: Date()), ledger.touched || ledger.hintID != current.id {
            self.current = nil
        }
    }
}
