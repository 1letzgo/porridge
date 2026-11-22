import Foundation
import SwiftData

/// The meeting flow around the calendar. The calendar is only read, and only to start or prepare a Record Meeting:
/// a small alert shortly before a meeting (a floating panel on the Mac, a notification on iOS) with Record and Join,
/// and the people invited as one-tap names for the speakers. Nothing is written to the calendar, no invitation is
/// answered, no reminder is set and no task comes from an appointment. DESIGN.md "Meetings from the calendar".
enum MeetingAlerts {
    // MARK: Settings (this device only)

    /// Alerts before meetings. Off unless calendar access was already given when this version first ran.
    static let enabledKey = "meetingAlerts"
    /// Calendars that do not alert (`EKCalendar.calendarIdentifier`): a calendar added later alerts.
    static let excludedCalendarsKey = "meetingAlertsExcludedCalendars"
    /// Mac: the minutes until the next meeting next to the microphone in the menu bar.
    static let countdownKey = "meetingCountdown"

    /// The alert comes this long before the start.
    static let lead: TimeInterval = 60
    /// After the start the alert still comes this long (the Mac was asleep, the app started late).
    static let grace: TimeInterval = 120
    /// The countdown in the menu bar shows from this long before a meeting.
    static let countdownWindow: TimeInterval = 30 * 60

    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [countdownKey: true])
    }

    /// Settles the switch once: on when the calendar can already be read, so nobody gets alerts they did not expect
    /// and nobody is asked for access by an update.
    static func settleDefault(granted: Bool, _ defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: enabledKey) == nil else { return }
        defaults.set(granted, forKey: enabledKey)
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var showsCountdown: Bool { UserDefaults.standard.bool(forKey: countdownKey) }

    static var excludedCalendars: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: excludedCalendarsKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: excludedCalendarsKey) }
    }

    // MARK: Which appointments alert

    /// A meeting: at a time of day, not declined, with somebody else invited or a video call.
    static func qualifies(_ appointment: CalendarAppointment, excluded: Set<String> = []) -> Bool {
        !appointment.isAllDay && !appointment.isDeclined && !excluded.contains(appointment.calendarID)
            && (!appointment.attendees.isEmpty || appointment.videoURL != nil)
    }

    /// The meetings still to come or just begun, in order of their start.
    static func upcoming(_ appointments: [CalendarAppointment], excluded: Set<String>, now: Date) -> [CalendarAppointment] {
        appointments
            .filter { qualifies($0, excluded: excluded) && $0.start.addingTimeInterval(grace) > now }
            .sorted { $0.start < $1.start }
    }

    /// Whether the alert of a meeting starting at `start` is due now.
    static func isAlertDue(start: Date, now: Date) -> Bool {
        now >= start.addingTimeInterval(-lead) && now < start.addingTimeInterval(grace)
    }

    /// One alert per appointment and start (a moved appointment alerts again).
    static func alertKey(_ appointment: CalendarAppointment) -> String {
        "\(appointment.id)@\(Int(appointment.start.timeIntervalSince1970))"
    }

    /// The menu bar countdown, "12m"; nil when the meeting is further away than `countdownWindow` or has begun.
    static func countdownText(until start: Date, now: Date) -> String? {
        let seconds = start.timeIntervalSince(now)
        guard seconds > 0, seconds <= countdownWindow else { return nil }
        return "\(max(1, Int((seconds / 60).rounded(.up))))m"
    }

    // MARK: Reading an appointment

    /// Hosts of video calls; a subdomain counts too ("company.zoom.us").
    static let videoHosts = [
        "zoom.us", "zoom.com", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com",
        "gotomeeting.com", "meet.goto.com", "facetime.apple.com", "chime.aws", "meet.jit.si", "around.co", "bluejeans.com",
    ]

    private static let linkPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>"'()\]]+"#, options: .caseInsensitive)

    /// The first link of a video call in the appointment's URL, place or notes.
    static func videoLink(in texts: [String?]) -> URL? {
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            for match in linkPattern.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                let raw = String(text[swiftRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:>"))
                guard let url = URL(string: raw), let host = url.host?.lowercased() else { continue }
                if videoHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }

    /// The name to offer for an invited person: their name, or the part of the address before the @ made readable
    /// ("anna.schmidt@firma.de" is "Anna Schmidt"); nil for neither.
    static func attendeeName(name: String?, address: String?) -> String? {
        let name = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, !name.contains("@") { return name }
        let mail = (name.contains("@") ? name : (address ?? ""))
            .replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
        guard let local = mail.split(separator: "@").first, !local.isEmpty else { return name.isEmpty ? nil : name }
        let words = local.split(whereSeparator: { "._-+".contains($0) }).filter { !$0.allSatisfy(\.isNumber) }
        guard !words.isEmpty else { return nil }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }

    /// Each name once (case-insensitive), in order.
    static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0.lowercased()).inserted }
    }

    /// "Anna, Tom and 2 more" for the alert; nil without anybody.
    static func peopleLine(_ names: [String], shown: Int = 2) -> String? {
        guard !names.isEmpty else { return nil }
        let first = names.prefix(shown).joined(separator: ", ")
        return names.count > shown ? String(localized: "\(first) and \(names.count - shown) more") : first
    }
}

/// Which appointment a recorded meeting was made for, kept on this device only (no new synced field): the meeting
/// started from an appointment stores its people here. On another device, or for a meeting from before, the
/// appointment is looked up in the calendar by the meeting's title and time.
@MainActor
enum MeetingLinks {
    static let key = "meetingAppointments"
    /// Records older than this are dropped.
    static let keepFor: TimeInterval = 180 * 86400

    private static var lookedUp: [UUID: CalendarAppointment?] = [:]

    static func remember(_ appointment: CalendarAppointment, for noteID: UUID, _ defaults: UserDefaults = .standard) {
        var all = stored(defaults)
        all[noteID.uuidString] = appointment
        let cutoff = Date().addingTimeInterval(-keepFor)
        all = all.filter { $0.value.start > cutoff }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
        lookedUp[noteID] = appointment
    }

    static func stored(_ defaults: UserDefaults = .standard) -> [String: CalendarAppointment] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: CalendarAppointment].self, from: data)) ?? [:]
    }

    /// The appointment a meeting was recorded for, if it is known or can be found; asked of the calendar once per
    /// meeting while the app runs.
    static func appointment(for note: Note) -> CalendarAppointment? {
        guard note.isRecording else { return nil }
        if let known = lookedUp[note.id] { return known }
        let found = stored()[note.id.uuidString] ?? find(for: note)
        lookedUp[note.id] = found
        return found
    }

    /// The people invited to the meeting's appointment.
    static func attendees(for note: Note) -> [String] {
        appointment(for: note)?.attendees ?? []
    }

    /// An appointment with the meeting's title that overlaps the recording (a meeting is created when it stops).
    private static func find(for note: Note) -> CalendarAppointment? {
        guard note.titleIsCustom, CalendarAccess.status == .granted else { return nil }
        let began = note.createdAt.addingTimeInterval(-max(note.duration, 0))
        let candidates = CalendarAccess.appointments(from: began.addingTimeInterval(-3 * 3600), to: note.createdAt.addingTimeInterval(3600))
        return match(title: note.title, began: began, ended: note.createdAt, in: candidates)
    }

    /// The appointment of that title closest to the recording, overlapping it with half an hour to spare.
    static func match(title: String, began: Date, ended: Date, in candidates: [CalendarAppointment]) -> CalendarAppointment? {
        let title = title.trimmingCharacters(in: .whitespaces)
        let slack: TimeInterval = 30 * 60
        return candidates
            .filter { !$0.isAllDay && $0.title.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(title) == .orderedSame }
            .filter { $0.start < ended.addingTimeInterval(slack) && $0.end > began.addingTimeInterval(-slack) }
            .min { abs($0.start.timeIntervalSince(began)) < abs($1.start.timeIntervalSince(began)) }
    }

    /// Forgets what was looked up (the calendar or the access changed).
    static func forgetLookups() { lookedUp = [:] }
}

/// Names offered for a speaker with one tap: the people invited to the meeting, then the user, each only while no
/// other speaker of the meeting has that name.
enum SpeakerNaming {
    static func choices(attendees: [String], myName: String?, speakers: [Speaker], for speakerID: String) -> [String] {
        let taken = Set(speakers.filter { $0.id != speakerID }.map { $0.name.lowercased() })
        let current = speakers.first { $0.id == speakerID }?.name.lowercased()
        let names = attendees.isEmpty ? [] : attendees + [myName].compactMap { $0 }
        return MeetingAlerts.unique(names).filter { !taken.contains($0.lowercased()) && $0.lowercased() != current }
    }

    /// The names to offer for a speaker of this meeting; empty when its appointment and its people are unknown.
    @MainActor
    static func choices(for speakerID: String, in note: Note) -> [String] {
        choices(attendees: MeetingLinks.attendees(for: note), myName: AppSettings.myName, speakers: note.speakers, for: speakerID)
    }

    /// Names a speaker: the voice is learned under the name (`VoiceProfiles`), earlier unnamed speakers are checked
    /// against it, and the summary follows (`ProcessingService.speakersRenamed`).
    @MainActor
    static func rename(_ speakerID: String, to rawName: String, in note: Note, context: ModelContext, processing: ProcessingService) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let old = note.speakers.first(where: { $0.id == speakerID })?.name, old != name else { return }
        note.speakers = VoiceProfiles.rename(speakerID: speakerID, to: name, in: note.speakers, context: context)
        try? context.save()
        VoiceProfiles.rematchAllMeetings(context: context)
        processing.speakersRenamed(note, from: old, to: name)
    }
}
