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
}

/// The appointments the Inbox shows (New, under its card): those of the day not filed into a bowl, each series once
/// (its occurrence of the day; the first one if it repeats within the day), all-day ones first, then by start. Never
/// another day's, never a filed one (that one is in its bowl and in Today). They are no entries: not counted in the
/// Inbox's badge, not part of Triage, Later or choosing several.
enum InboxAppointments {
    static func rows(_ appointments: [CalendarAppointment], bowls: [String: AppointmentLedger.BowlLink], day: Date, calendar: Calendar = .current) -> [CalendarAppointment] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        var seen = Set<String>()
        return appointments
            .filter { $0.start < end && ($0.end > start || $0.start >= start) && bowls[$0.seriesID]?.bowl == nil }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
            .filter { seen.insert($0.seriesID).inserted }
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
        return notes.filter { ids.contains($0.id.uuidString) && !$0.isDeleted }.sorted { $0.createdAt > $1.createdAt }
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

    /// The day's appointments for the Inbox among these (`InboxAppointments`).
    func inboxAppointments(among appointments: [CalendarAppointment], day: Date = Date()) -> [CalendarAppointment] {
        InboxAppointments.rows(appointments, bowls: ledger.bowls, day: day)
    }

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
