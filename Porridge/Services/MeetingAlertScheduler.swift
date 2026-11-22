import Foundation
#if os(iOS)
import UIKit
import UserNotifications
#endif

/// Keeps the meetings of the next hours at hand for the alerts (`MeetingAlerts`): read again when a calendar
/// changes, when the settings change and every few minutes. On iOS it plans one local notification per meeting with
/// Record (and Join for a video call); on the Mac `MeetingAlertController` shows its floating panel from `upcoming`.
@MainActor
final class MeetingAlertScheduler {
    static let shared = MeetingAlertScheduler()

    /// Meetings that alert, still to come or just begun, in order.
    private(set) var upcoming: [CalendarAppointment] = []
    /// Called after every read (the Mac's menu bar countdown and panel).
    var onChange: (() -> Void)?

    /// How far ahead the meetings are read.
    static let horizon: TimeInterval = 36 * 3600
    private var started = false
    private var lastRead = Date.distantPast

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        MeetingAlerts.registerDefaults()
        #if os(iOS)
        // On iOS the alerts are notifications: on by themselves only when those are allowed already too. Nothing is
        // asked for here; only the switch in Settings asks (`enable`).
        Task {
            let allowed = await MeetingNotifications.isAllowed()
            MeetingAlerts.settleDefault(granted: CalendarAccess.status == .granted && allowed)
            MeetingAlertScheduler.shared.refresh()
        }
        #else
        MeetingAlerts.settleDefault(granted: CalendarAccess.status == .granted)
        #endif
        NotificationCenter.default.addObserver(forName: CalendarAccess.changedNotification, object: CalendarAccess.eventStore, queue: .main) { _ in
            MainActor.assumeIsolated {
                MeetingLinks.forgetLookups()
                MeetingAlertScheduler.shared.refresh()
            }
        }
        #if os(iOS)
        // The notifications' delegate is set at launch (`PorridgeAppDelegate`), so Record works from a cold start too.
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MeetingAlertScheduler.shared.refresh() }
        }
        #endif
        refresh()
    }

    /// Reads the meetings again only when the last read is a few minutes old (the Mac's clock ticks often).
    func refreshIfStale(now: Date = Date()) {
        if now.timeIntervalSince(lastRead) >= 5 * 60 { refresh() }
    }

    /// Reads the meetings of the next hours and plans the alerts; nothing when alerts are off or the calendar is shut.
    func refresh() {
        lastRead = Date()
        if MeetingAlerts.isEnabled, CalendarAccess.status == .granted {
            let now = Date()
            let read = CalendarAccess.appointments(from: now.addingTimeInterval(-MeetingAlerts.grace), to: now.addingTimeInterval(Self.horizon))
            upcoming = MeetingAlerts.upcoming(read, excluded: MeetingAlerts.excludedCalendars, now: now)
        } else {
            upcoming = []
        }
        #if os(iOS)
        MeetingNotifications.plan(upcoming)
        #endif
        onChange?()
    }

    /// The setting was switched on: the calendar (and on iOS the notifications) are asked for once, then read.
    func enable() async {
        UserDefaults.standard.set(true, forKey: MeetingAlerts.enabledKey)
        if CalendarAccess.status == .notDetermined { _ = await CalendarAccess.requestAccess() }
        #if os(iOS)
        await MeetingNotifications.requestPermission()
        #endif
        MeetingLinks.forgetLookups()
        refresh()
    }

    func disable() {
        UserDefaults.standard.set(false, forKey: MeetingAlerts.enabledKey)
        refresh()
    }

    // MARK: Recording from an alert

    /// The appointment a Record from an alert was tapped for, until the list takes it (`QuickAction.startMeeting`).
    private(set) var pendingRecord: CalendarAppointment?

    func requestRecording(_ appointment: CalendarAppointment) {
        pendingRecord = appointment
        QuickActionCenter.request(.startMeeting)
    }

    func takePendingRecord() -> CalendarAppointment? {
        defer { pendingRecord = nil }
        return pendingRecord
    }
}

#if os(iOS)
/// The notification shortly before a meeting, with Record and, for a video call, Join. Planned for the meetings of
/// the next hours whenever the app runs; a meeting moved while the app was closed alerts at its old time.
@MainActor
enum MeetingNotifications {
    static let prefix = "meeting-"
    static let category = "meeting"
    static let videoCategory = "meeting.video"
    static let recordAction = "record"
    static let joinAction = "join"
    static let appointmentKey = "appointment"
    /// iOS keeps at most 64 planned notifications per app.
    static let maximum = 20

    private static let delegate = Delegate()

    static func register() {
        let record = UNNotificationAction(identifier: recordAction, title: String(localized: "Record"), options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "mic.fill"))
        let join = UNNotificationAction(identifier: joinAction, title: String(localized: "Join"), options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "video.fill"))
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [record], intentIdentifiers: []),
            UNNotificationCategory(identifier: videoCategory, actions: [record, join], intentIdentifiers: []),
        ])
        center.delegate = delegate
    }

    /// Notifications may be shown (allowed, or quietly on trial).
    static func isAllowed() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    static func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Replaces the planned meeting notifications with those of `meetings`.
    static func plan(_ meetings: [CalendarAppointment]) {
        Task {
            let center = UNUserNotificationCenter.current()
            let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: old)
            // Never asks: only planned when notifications are allowed (asked for by the switch in Settings).
            guard !meetings.isEmpty, await isAllowed() else { return }
            let now = Date()
            for meeting in meetings.prefix(maximum) {
                let wait = meeting.start.addingTimeInterval(-MeetingAlerts.lead).timeIntervalSince(now)
                guard wait > 1, let data = try? JSONEncoder().encode(meeting) else { continue }
                let content = UNMutableNotificationContent()
                content.title = meeting.title
                let time = meeting.start.formatted(.dateTime.hour().minute())
                content.body = MeetingAlerts.peopleLine(meeting.attendees).map { String(localized: "Starts at \(time) · with \($0)") }
                    ?? String(localized: "Starts at \(time)")
                content.sound = .default
                content.categoryIdentifier = meeting.videoURL == nil ? category : videoCategory
                content.userInfo = [appointmentKey: data]
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: prefix + MeetingAlerts.alertKey(meeting), content: content, trigger: trigger))
            }
        }
    }

    static func handle(action: String, userInfo: [AnyHashable: Any]) {
        guard let data = userInfo[appointmentKey] as? Data,
              let appointment = try? JSONDecoder().decode(CalendarAppointment.self, from: data) else { return }
        switch action {
        case joinAction:
            if let url = appointment.videoURL { UIApplication.shared.open(url) }
        case recordAction:
            MeetingAlertScheduler.shared.requestRecording(appointment)
        default:
            // A tap on the notification itself only opens the app.
            break
        }
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        /// Shown as a banner while the app is open too (meeting alerts, entries back from Later).
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
            let id = notification.request.identifier
            return id.hasPrefix(MeetingNotifications.prefix) || id.hasPrefix(InboxSnoozeScheduler.prefix) ? [.banner, .sound] : []
        }

        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
            let action = response.actionIdentifier
            let info = response.notification.request.content.userInfo
            await MainActor.run { MeetingNotifications.handle(action: action, userInfo: info) }
        }
    }
}
#endif
