import Foundation

/// The one-time "What's New" card at the top of Today (iPhone and Mac) after the update to the three places: what
/// moved and where it went. Shown once to someone who used the app before; a new install learns the same in the
/// onboarding and never sees the card. Kept on this device only (UserDefaults), never synced.
enum WhatsNew {
    /// Set once the card was dismissed (or the onboarding was finished with the three places in it).
    static let seenKey = "whatsNewSeen"

    struct Item: Hashable, Sendable {
        var symbol: String
        var title: String
        var text: String
    }

    static let title = String(localized: "What’s New in Porridge")

    /// What changed, in the order of the card. `mac`: the Mac's words (sidebar, ⌘K, keys).
    static func items(mac: Bool) -> [Item] {
        [
            Item(
                symbol: "square.grid.2x2", title: String(localized: "Three Places"),
                text: mac
                    ? String(localized: "Today, Inbox and Bowls lead the sidebar (⌘1–3); Chat has its own row (⌘4).")
                    : String(localized: "Today, Inbox and Bowls are tabs; Chat and Search have their own. Settings is the gear in the Bowls bar.")
            ),
            Item(
                symbol: "info.circle", title: String(localized: "Details"),
                text: mac
                    ? String(localized: "Bowl, due date, tags, appointment and speakers are in the inspector (⌥⌘I).")
                    : String(localized: "Bowl, due date, tags, appointment and speakers are in Details: tap the line under an entry’s title.")
            ),
            Item(
                symbol: "magnifyingglass", title: String(localized: "Search or Ask"),
                text: mac
                    ? String(localized: "One field (⌘K) searches, goes to a bowl or runs a command; ⌘↩ asks Porridge in the Chat.")
                    : String(localized: "One field searches and goes to a bowl or place; “Ask Porridge” hands the question to the Chat tab.")
            ),
            Item(
                symbol: "bolt.fill", title: String(localized: "Triage"),
                text: mac
                    ? String(localized: "Go through the Inbox one entry at a time: F files, L puts away for later, ⌫ deletes.")
                    : String(localized: "The bolt in the Inbox goes through new entries one at a time: File, Later, Skip, Delete.")
            ),
            Item(
                symbol: "hand.draw", title: mac ? String(localized: "Filing") : String(localized: "Inbox Swipes"),
                text: mac
                    ? String(localized: "“✦ Bowl” after an Inbox entry files it into the suggested bowl in one click.")
                    : String(localized: "Swipe right to file into the suggested bowl, left for Later or Delete.")
            ),
            Item(
                symbol: "checkmark.circle", title: String(localized: "Choosing Several"),
                text: mac
                    ? String(localized: "Select several entries and the inspector changes what they have in common.")
                    : String(localized: "Select turns the tab bar into Move · Later · Done · More.")
            ),
            Item(
                symbol: "calendar", title: String(localized: "Today Shows What Is Open"),
                text: String(localized: "A ticked to-do leaves Today (with Undo) and stays in its bowl.")
            ),
        ]
    }

    /// The last page of the onboarding: the places and what each is for (iPhone tabs, Mac sidebar).
    static func places(mac: Bool) -> [Item] {
        [
            Item(symbol: "calendar", title: String(localized: "Today"), text: String(localized: "Appointments and the to-dos that are due.")),
            Item(symbol: "tray.fill", title: String(localized: "Inbox"), text: String(localized: "Everything new lands here first, until it is filed into a bowl.")),
            Item(symbol: "folder.fill", title: String(localized: "Bowls"), text: mac
                ? String(localized: "One bowl per topic, the smart filters, Archive and Recently Deleted.")
                : String(localized: "One bowl per topic, the smart filters, Archive, Recently Deleted and Settings.")),
            Item(symbol: "bubble.left.and.bubble.right.fill", title: String(localized: "Chat"), text: String(localized: "Ask about your notes; answers name their sources.")),
            Item(symbol: "magnifyingglass", title: mac ? String(localized: "Search or Ask (⌘K)") : String(localized: "Search"),
                 text: String(localized: "Find any entry, go to a bowl, or ask Porridge.")),
        ]
    }

    /// Whether the card shows: the onboarding was done (an earlier version ran here) and the card not dismissed.
    static func shows(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: AppSettings.onboardingDoneKey) && !defaults.bool(forKey: seenKey)
    }

    static func dismiss(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: seenKey)
    }
}
