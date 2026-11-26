import Foundation
import Observation
import SwiftData

/// An appointment as an entry remembers it: enough to show it without the calendar (another device, no access, a
/// day long gone) and to find it again in the calendar.
struct AppointmentRef: Codable, Hashable {
    /// The occurrence: series and start (`key(seriesID:start:)`).
    var key: String
    /// The series (`CalendarAppointment.seriesID`): every occurrence of a repeating appointment shares it.
    var seriesID: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool

    init(_ appointment: CalendarAppointment) {
        key = appointment.key
        seriesID = appointment.seriesID
        title = appointment.title
        start = appointment.start
        end = appointment.end
        isAllDay = appointment.isAllDay
    }

    static func key(seriesID: String, start: Date) -> String {
        "\(seriesID)|\(Int(start.timeIntervalSince1970.rounded()))"
    }

    /// The same occurrence: the same key, or the same series on the same day (the appointment was moved within it).
    func matches(_ appointment: CalendarAppointment, calendar: Calendar = .current) -> Bool {
        key == appointment.key || (seriesID == appointment.seriesID && calendar.isDate(start, inSameDayAs: appointment.start))
    }

    /// "Today, 10:00", "Mon 24 Nov, 10:00" or, all day, only the day.
    var when: String { AppointmentRef.when(start: start, isAllDay: isAllDay) }

    static func when(start: Date, isAllDay: Bool, calendar: Calendar = .current) -> String {
        let day: String
        if calendar.isDateInToday(start) {
            day = String(localized: "Today")
        } else if calendar.isDateInYesterday(start) {
            day = String(localized: "Yesterday")
        } else if calendar.isDateInTomorrow(start) {
            day = String(localized: "Tomorrow")
        } else {
            day = start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        return isAllDay ? day : "\(day), \(start.formatted(date: .omitted, time: .shortened))"
    }
}

/// Which entries belong to which appointment, and which bowl an appointment (a whole series) belongs to. Synced
/// through iCloud key-value storage, not CloudKit records: each link keeps when it changed, and the two sides are
/// merged link by link. A removed link stays as a tombstone for a while, so that it is not brought back by a device
/// that did not see the removal, and so that a meeting is not linked again automatically.
struct AppointmentLedger: Codable, Equatable {
    struct NoteLink: Codable, Equatable {
        /// nil: the link was removed.
        var ref: AppointmentRef?
        var changedAt: Date
    }

    struct BowlLink: Codable, Equatable {
        /// `Projects.key` of the bowl; nil: taken out of its bowl.
        var bowl: String?
        var changedAt: Date
    }

    /// By note id.
    var notes: [String: NoteLink] = [:]
    /// By series (`AppointmentRef.seriesID`).
    var bowls: [String: BowlLink] = [:]

    /// Link by link, the later change wins.
    static func merged(_ a: AppointmentLedger?, _ b: AppointmentLedger?) -> AppointmentLedger {
        guard let a else { return b ?? AppointmentLedger() }
        guard let b else { return a }
        var result = a
        for (id, link) in b.notes where (result.notes[id]?.changedAt ?? .distantPast) < link.changedAt {
            result.notes[id] = link
        }
        for (id, link) in b.bowls where (result.bowls[id]?.changedAt ?? .distantPast) < link.changedAt {
            result.bowls[id] = link
        }
        return result
    }

    /// Without tombstones older than `keepTombstones`.
    func pruned(now: Date = Date()) -> AppointmentLedger {
        var result = self
        let cutoff = now.addingTimeInterval(-AppointmentLedger.keepTombstones)
        result.notes = notes.filter { $0.value.ref != nil || $0.value.changedAt > cutoff }
        result.bowls = bowls.filter { $0.value.bowl != nil || $0.value.changedAt > cutoff }
        return result
    }

    static let keepTombstones: TimeInterval = 90 * 86400

    /// The bowl is gone (deleted, or a shared bowl left): the series filed into it are taken out of it (a tombstone
    /// each), so their appointments show in Today again (and can be filed anew) instead of nowhere.
    func forgettingBowl(_ bowl: String, now: Date = Date()) -> AppointmentLedger {
        var result = self
        for (series, link) in bowls where link.bowl == bowl {
            result.bowls[series] = BowlLink(bowl: nil, changedAt: now)
        }
        return result
    }

    /// The entries are gone (copies of a shared bowl that were deleted): their links are removed (a tombstone each).
    func forgettingNotes(_ ids: Set<String>, now: Date = Date()) -> AppointmentLedger {
        var result = self
        for id in ids where notes[id]?.ref != nil {
            result.notes[id] = NoteLink(ref: nil, changedAt: now)
        }
        return result
    }

    /// `to` (an entry of my own made from a copy) is linked as `from` is, unless it has a link already.
    func copyingLink(from: String, to: String, now: Date = Date()) -> AppointmentLedger {
        guard let ref = notes[from]?.ref, notes[to] == nil else { return self }
        var result = self
        result.notes[to] = NoteLink(ref: ref, changedAt: now)
        return result
    }
}

/// The appointments a bowl shows: those of the series filed into it (by hand, from an appointment's Bowl menu), one row
/// per series, never each occurrence: its next occurrence that is not over, else its last one. Upcoming ones first
/// (soonest first), then past ones (latest first). Appointments never show in the Inbox: they are no entries; what is
/// linked to an appointment of a bowl goes into that bowl (`AppointmentLinks.setBowl`, `link`).
enum BowlAppointments {
    static func rows(_ appointments: [CalendarAppointment], bowl: String, bowls: [String: AppointmentLedger.BowlLink], now: Date = Date()) -> [CalendarAppointment] {
        var bySeries: [String: [CalendarAppointment]] = [:]
        for appointment in appointments where bowls[appointment.seriesID]?.bowl == bowl {
            bySeries[appointment.seriesID, default: []].append(appointment)
        }
        let picked = bySeries.values.compactMap { occurrences -> CalendarAppointment? in
            let sorted = occurrences.sorted { $0.start < $1.start }
            return sorted.first { $0.end > now } ?? sorted.last
        }
        let upcoming = picked.filter { $0.end > now }.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
        let past = picked.filter { $0.end <= now }.sorted { ($0.start, $0.title) > ($1.start, $1.title) }
        return upcoming + past
    }

    /// How many appointments each bowl shows (each series once, as `rows`), by the bowl's key, in one pass.
    static func counts(_ appointments: [CalendarAppointment], bowls: [String: AppointmentLedger.BowlLink]) -> [String: Int] {
        var series: [String: Set<String>] = [:]
        for appointment in appointments {
            if let bowl = bowls[appointment.seriesID]?.bowl { series[bowl, default: []].insert(appointment.seriesID) }
        }
        return series.mapValues(\.count)
    }

    /// "1 appointment", "3 appointments"; nil for none.
    static func phrase(_ count: Int) -> String? {
        count == 0 ? nil : count == 1 ? String(localized: "1 appointment") : String(localized: "\(count) appointments")
    }
}

/// A bowl's list with its appointments as rows among the entries (owner revision 8): each appointment of the bowl
/// (`BowlAppointments.rows`, one per series) stands where the date of its occurrence shown puts it among the entries
/// (pinned entries first, then newest first: an upcoming appointment comes before every entry, a past one among those
/// changed around its day). Under it, moved in a little as in Today (`AppointmentLinks.underAppointment`), the
/// entries of this bowl linked to any occurrence of its series; those are not listed again at their own place. An
/// entry linked to an appointment that is not one of the bowl's rows (filed elsewhere, or outside the calendar
/// window) stands at its own place; entries linked to it in other bowls or the Inbox are not shown here.
enum BowlListing {
    enum Row: Identifiable {
        case note(Note)
        /// The appointment and the entries under it, in their order.
        case appointment(CalendarAppointment, linked: [Note])

        var id: String {
            switch self {
            case .note(let note): "note-" + note.id.uuidString
            case .appointment(let appointment, _): "appointment-" + appointment.seriesID
            }
        }
    }

    /// `entries`: the bowl's entries in its order (`Projects.ordered`); `appointments`: the bowl's appointments;
    /// `seriesOf`: the series an entry is linked to (`AppointmentLinks.appointment(for:)`).
    static func rows(_ entries: [Note], appointments: [CalendarAppointment], seriesOf: (Note) -> String?) -> [Row] {
        guard !appointments.isEmpty else { return entries.map { .note($0) } }
        let series = Set(appointments.map(\.seriesID))
        var linked: [String: [Note]] = [:]
        var rest: [Note] = []
        for note in entries {
            if let id = seriesOf(note), series.contains(id) { linked[id, default: []].append(note) } else { rest.append(note) }
        }
        let pinned = rest.prefix { $0.isPinned }
        var others = rest.dropFirst(pinned.count)
        var rows = pinned.map { Row.note($0) }
        for appointment in appointments.sorted(by: { ($0.start, $0.title) > ($1.start, $1.title) }) {
            while let next = others.first, next.updatedAt >= appointment.start {
                rows.append(.note(next))
                others = others.dropFirst()
            }
            rows.append(.appointment(appointment, linked: AppointmentLinks.underAppointment(linked[appointment.seriesID] ?? [])))
        }
        rows += others.map { .note($0) }
        return rows
    }
}

/// Entries linked to calendar appointments (a meeting recorded for one is linked by itself), and appointments
/// filed into bowls: what is linked to an appointment of a bowl goes into that bowl while it is in the inbox.
@MainActor
@Observable
final class AppointmentLinks {
    static let shared = AppointmentLinks()
    static let storageKey = "appointmentLinks"

    private(set) var ledger = AppointmentLedger()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cloud: NSUbiquitousKeyValueStore?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, cloud: NSUbiquitousKeyValueStore? = .default) {
        self.defaults = defaults
        self.cloud = cloud
        ledger = Self.decode(defaults.data(forKey: Self.storageKey)) ?? AppointmentLedger()
        if let cloud {
            observer = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.followCloud() }
            }
            cloud.synchronize()
            followCloud()
        }
    }

    // MARK: Entries

    /// The appointment the entry is linked to.
    func appointment(for noteID: UUID) -> AppointmentRef? {
        ledger.notes[noteID.uuidString]?.ref
    }

    /// The entries linked to the appointment, among these notes (deleted ones left out), newest first.
    func notes(for appointment: CalendarAppointment, among notes: [Note]) -> [Note] {
        let ids = Set(ledger.notes.compactMap { id, link in link.ref?.matches(appointment) == true ? id : nil })
        return Self.underAppointment(notes.filter { ids.contains($0.id.uuidString) && !$0.isDeleted })
    }

    /// The order of the entries under an appointment, in Today and in its bowl (`BowlListing`): newest first.
    nonisolated static func underAppointment(_ linked: [Note]) -> [Note] {
        linked.sorted { $0.createdAt > $1.createdAt }
    }

    /// The bowl's list with its appointments among the entries (`BowlListing`): `entries` in the bowl's order,
    /// `appointments` the bowl's (`appointments(inBowl:among:)`).
    func bowlRows(_ entries: [Note], appointments: [CalendarAppointment]) -> [BowlListing.Row] {
        BowlListing.rows(entries, appointments: appointments) { [ledger] note in ledger.notes[note.id.uuidString]?.ref?.seriesID }
    }

    /// The other entries linked to the same appointment as this one, newest first.
    func others(linkedWith note: Note, among notes: [Note]) -> [Note] {
        guard let ref = appointment(for: note.id) else { return [] }
        let ids = Set(ledger.notes.compactMap { id, link in link.ref?.key == ref.key ? id : nil })
        return notes.filter { $0.id != note.id && ids.contains($0.id.uuidString) && !$0.isDeleted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Links the entry to the appointment (nil: unlinks it). An entry in the inbox goes into the appointment's bowl.
    func link(_ note: Note, to appointment: CalendarAppointment?, in context: ModelContext?, now: Date = Date()) {
        let ref = appointment.map(AppointmentRef.init)
        guard ledger.notes[note.id.uuidString]?.ref != ref else { return }
        ledger.notes[note.id.uuidString] = .init(ref: ref, changedAt: now)
        save()
        if let appointment, let context { fileIntoBowl([note], of: appointment, in: context) }
    }

    /// Links a meeting recorded for the appointment, unless it was linked (or unlinked by hand) before.
    func linkMeeting(_ note: Note, to appointment: CalendarAppointment, in context: ModelContext?) {
        guard ledger.notes[note.id.uuidString] == nil else { return }
        link(note, to: appointment, in: context)
    }

    /// Links the meetings recorded for an appointment on this device (`MeetingLinks.stored`) and the recent ones
    /// that match one by title and time, while they are not linked yet (nor unlinked by hand).
    func linkRecentMeetings(_ notes: [Note], in context: ModelContext, now: Date = Date()) {
        let recorded = MeetingLinks.stored()
        let since = now.addingTimeInterval(-14 * 86400)
        let granted = CalendarAccess.status == .granted
        for note in notes where note.isRecording && !note.isDeleted && ledger.notes[note.id.uuidString] == nil {
            if let appointment = recorded[note.id.uuidString] {
                linkMeeting(note, to: appointment, in: context)
            } else if granted, note.createdAt > since, let appointment = MeetingLinks.appointment(for: note) {
                linkMeeting(note, to: appointment, in: context)
            }
        }
    }

    // MARK: Bowls

    /// The bowl (`Projects.key`) the appointment's series is filed into.
    func bowl(for appointment: CalendarAppointment) -> String? {
        ledger.bowls[appointment.seriesID]?.bowl
    }

    /// How many appointments each bowl shows (`BowlAppointments.counts`), by the bowl's key: for the lists of bowls,
    /// which so ask the calendar once (`TodayCalendar.windowAppointments`, kept until the calendar changes) and count
    /// again only when the calendar or a filing changed.
    func appointmentCounts() -> [String: Int] {
        let calendar = TodayCalendar.shared
        guard calendar.status == .granted else { return [:] }
        let window = calendar.windowAppointments()
        let token = calendar.windowToken
        if let cached = countsCache, cached.token == token, cached.bowls == ledger.bowls { return cached.counts }
        let counts = BowlAppointments.counts(window, bowls: ledger.bowls)
        countsCache = (token, ledger.bowls, counts)
        return counts
    }

    @ObservationIgnored private var countsCache: (token: Int, bowls: [String: AppointmentLedger.BowlLink], counts: [String: Int])?

    /// The bowl's appointments among these (`BowlAppointments`).
    func appointments(inBowl bowl: String, among appointments: [CalendarAppointment], now: Date = Date()) -> [CalendarAppointment] {
        BowlAppointments.rows(appointments, bowl: bowl, bowls: ledger.bowls, now: now)
    }

    func bowl(forSeries seriesID: String) -> String? {
        ledger.bowls[seriesID]?.bowl
    }

    /// Files the appointment (every occurrence of its series) into a bowl, or out of it (nil); what is linked to it
    /// and waits in the inbox goes into the bowl.
    func setBowl(_ bowl: String?, for appointment: CalendarAppointment, notes: [Note], in context: ModelContext, now: Date = Date()) {
        guard ledger.bowls[appointment.seriesID]?.bowl != bowl else { return }
        ledger.bowls[appointment.seriesID] = .init(bowl: bowl, changedAt: now)
        save()
        let linked = notes.filter { note in ledger.notes[note.id.uuidString]?.ref?.seriesID == appointment.seriesID }
        fileIntoBowl(linked, of: appointment, in: context)
    }

    private func fileIntoBowl(_ notes: [Note], of appointment: CalendarAppointment, in context: ModelContext) {
        guard let bowl = bowl(for: appointment), !BowlSharing.shared.isReadOnly(UUID(uuidString: bowl)) else { return }
        let folders = (try? context.fetch(FetchDescriptor<NoteFolder>())) ?? []
        guard folders.contains(where: { Projects.key($0) == bowl && !$0.isArchived }) else { return }
        for note in notes where note.isInInbox && !BowlSharing.shared.isReadOnly(note) {
            Inbox.file(note, into: bowl, in: context)
        }
    }

    // MARK: Gone

    /// A bowl was deleted or left: what was filed into it is no longer (`AppointmentLedger.forgettingBowl`).
    func bowlWasDeleted(_ bowl: String, now: Date = Date()) {
        let changed = ledger.forgettingBowl(bowl, now: now)
        guard changed != ledger else { return }
        ledger = changed
        save()
    }

    /// Entries were deleted for good (copies of a shared bowl): their links go.
    func notesWereDeleted(_ ids: Set<String>, now: Date = Date()) {
        let changed = ledger.forgettingNotes(ids, now: now)
        guard changed != ledger else { return }
        ledger = changed
        save()
    }

    /// An entry of my own was made from a copy (`SharedBowlEnding.fork`): it keeps the copy's appointment.
    func copyLink(from: UUID, to: UUID, now: Date = Date()) {
        let changed = ledger.copyingLink(from: from.uuidString, to: to.uuidString, now: now)
        guard changed != ledger else { return }
        ledger = changed
        save()
    }

    // MARK: Storage

    private static func decode(_ data: Data?) -> AppointmentLedger? {
        data.flatMap { try? JSONDecoder().decode(AppointmentLedger.self, from: $0) }
    }

    private func save() {
        ledger = ledger.pruned()
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: Self.storageKey)
        cloud?.set(data, forKey: Self.storageKey)
    }

    /// Takes on what other devices changed.
    private func followCloud() {
        let merged = AppointmentLedger.merged(ledger, Self.decode(cloud?.data(forKey: Self.storageKey)))
        guard merged != ledger else { return }
        ledger = merged
        save()
    }
}
