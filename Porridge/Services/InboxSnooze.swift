import Foundation
import UserNotifications

/// What is left of "Later" (owner revision 9 took it away: things stay in the Inbox until they are filed into a
/// bowl). An entry put away for later carried, in the JSON object of `Note.todoSuggestionsRaw`, the keys `@snooze`
/// (the time it came back), `@snoozeBy` (the device it was chosen on) and, when the note had no suggestion states,
/// `@unoffered`. Nothing reads the time any more: the Inbox shows every entry in no bowl. Notes synced with the keys
/// keep them until their suggestions are next changed (`pruned`), and `@unoffered` still says that no suggestions
/// were offered. Notifications that were planned for coming back are taken away at launch.
enum InboxSnooze {
    static let storageKey = "@snooze"
    /// Marks an object that existed only for the snooze: no to-do suggestions were offered for the note.
    static let unofferedKey = "@unoffered"
    static let deviceKey = "@snoozeBy"
    /// The identifiers of the "Back from Later" notifications.
    nonisolated static let notificationPrefix = "snooze-"

    /// The states without the keys of "Later".
    static func pruned(_ states: [String: String]) -> [String: String] {
        states.filter { $0.key != storageKey && $0.key != deviceKey && $0.key != unofferedKey }
    }

    /// "Back from Later" notifications planned before the update would ring for entries that never left the Inbox.
    static func removePlannedNotifications() {
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(notificationPrefix) }
            if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
        }
    }
}
