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
                    ? String(localized: "Today, Inbox, To-dos and Bowls lead the sidebar (⌘1–4); Chat has its own row (⌘5).")
                    : String(localized: "Today, Inbox, Bowls and Search are the tabs, with the big “+” in the middle to add anything. Settings is the gear in Search.")
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
                    : String(localized: "One field searches and goes to a bowl or place. Switch the Search tab to Chat to ask Porridge, or tap “Ask Porridge”.")
            ),
            Item(
                symbol: "bolt.fill", title: String(localized: "Triage"),
                text: mac
                    ? String(localized: "Go through the Inbox one entry at a time: F files, J skips, ⌫ deletes.")
                    : String(localized: "The bolt in the Inbox goes through new entries one at a time: File, Skip, Delete.")
            ),
            Item(
                symbol: "hand.draw", title: mac ? String(localized: "Filing") : String(localized: "Inbox Swipes"),
                text: mac
                    ? String(localized: "“✦ Bowl” after an Inbox entry files it into the suggested bowl in one click.")
                    : String(localized: "Swipe right to file into the suggested bowl, left to delete.")
            ),
            Item(
                symbol: "checkmark.circle", title: String(localized: "Choosing Several"),
                text: mac
                    ? String(localized: "Select several entries and the inspector changes what they have in common.")
                    : String(localized: "Select turns the tab bar into Move · Done · More.")
            ),
            Item(
                symbol: "calendar", title: String(localized: "Today Shows What Is Open"),
                text: mac
                    ? String(localized: "A ticked to-do leaves Today (with Undo) and stays in its bowl. Every open to-do is in To-dos, the row after the Inbox; the Weekly Review is a button in Today’s head.")
                    : String(localized: "A ticked to-do leaves Today (with Undo) and stays in its bowl. Every open to-do is on the To-dos side of the Inbox; the Weekly Review opens from Today’s bar.")
            ),
        ]
    }

    /// The last page of the onboarding: the places and what each is for. iPhone: the tab bar from left to right
    /// (Today, Inbox with To-dos, "+", Bowls, Search with Chat); Mac: the sidebar (To-dos and Chat have their own rows)
    /// and the field.
    static func places(mac: Bool) -> [Item] {
        let today = Item(symbol: "calendar", title: String(localized: "Today"), text: String(localized: "Appointments and the to-dos that are due."))
        let inbox = Item(symbol: "tray.fill", title: String(localized: "Inbox"), text: mac
            ? String(localized: "Everything new lands here first and stays until it is filed into a bowl.")
            : String(localized: "Everything new lands here first and stays until it is filed into a bowl; the switch on top shows every open to-do."))
        let todos = Item(symbol: "checklist", title: String(localized: "To-dos"), text: String(localized: "Every open to-do, from the Inbox and every bowl, by when it is due."))
        let bowls = Item(symbol: Places.bowlsSymbol, title: String(localized: "Bowls"), text: mac
            ? String(localized: "One bowl per topic and the smart filters; Archive and Recently Deleted have their own rows.")
            : String(localized: "One bowl per topic, the smart filters and the Archive; the trash shows Recently Deleted."))
        if mac {
            return [
                today, inbox, todos, bowls,
                Item(symbol: "bubble.left.and.bubble.right.fill", title: String(localized: "Chat"), text: String(localized: "Ask about your notes; answers name their sources.")),
                Item(symbol: "magnifyingglass", title: String(localized: "Search or Ask (⌘K)"), text: String(localized: "Find any entry, go to a bowl, or ask Porridge.")),
            ]
        }
        return [
            today, inbox,
            Item(symbol: "plus.circle.fill", title: String(localized: "Add"), text: String(localized: "The big “+” in the middle of the tab bar adds a note, to-do, meeting, link or file where you are.")),
            bowls,
            Item(symbol: "magnifyingglass", title: String(localized: "Search and Chat"),
                 text: String(localized: "Find any entry or go to a bowl; switch to Chat to ask about your notes, with sources.")),
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
