import Foundation

/// A meeting's summary written again after its speakers were named, so names and task owners are right
/// ("Speaker 2 sends the offer" becomes "Anna sends the offer"). The renames of a few seconds make one new summary
/// (`ProcessingService.speakersRenamed`).
///
/// Only what the user would have gotten anyway: the summary is rewritten only when the meeting has one, automatic
/// summaries are on ("Summarize Incoming Entries"), the model of the last summary (or else the default) can run
/// without a download, and the summary is still as the model wrote it: one edited by hand or with ticked tasks keeps
/// the user's work, and only gets the old name replaced by the new one in its text. A summary this device has no
/// record of (older, or written on another device) counts as edited. The template is the one last
/// chosen for the meeting on this device, else General. All of this is kept on this device only.
enum SummaryRefresh {
    /// Renames within this time make one new summary.
    static let debounce: Duration = .seconds(6)

    static let writtenKey = "summaryWrittenHashes"
    static let templateKey = "summaryTemplateChoices"
    /// Records kept per store; older ones beyond it are dropped in no particular order.
    static let limit = 400

    // MARK: Deciding

    /// Whether a summary may be written again by itself after a rename.
    static func shouldRefresh(summary: String?, writtenHash: String?, autoEnabled: Bool, hasModel: Bool) -> Bool {
        guard autoEnabled, hasModel, let summary, !summary.isEmpty else { return false }
        return isUntouched(summary, writtenHash: writtenHash)
    }

    /// The summary is as the model wrote it: no ticked task, and no edit since. Without a record of what was written
    /// (an older meeting, or one summarized on another device) nobody can tell, so it counts as touched and is kept.
    static func isUntouched(_ summary: String, writtenHash: String?) -> Bool {
        if SummaryTasks.parse(summary).contains(where: \.done) { return false }
        guard let writtenHash else { return false }
        return writtenHash == hash(summary)
    }

    /// The model to write with: the one of the last summary (by its label) when it can still run, else the default
    /// when it can run without a download; nil for none.
    static func model(lastLabel: String?, available: [SummaryModel], isUsable: (SummaryModel) -> Bool, fallback: SummaryModel?) -> SummaryModel? {
        if let lastLabel, let last = available.first(where: { $0.label == lastLabel }), isUsable(last) { return last }
        return fallback
    }

    // MARK: Names in the text

    /// Replaces a whole name in the text: "Speaker 1" is not part of "Speaker 10", "Ann" not of "Anna".
    static func replacingName(_ old: String, with new: String, in text: String) -> String {
        let old = old.trimmingCharacters(in: .whitespaces)
        guard !old.isEmpty, old != new else { return text }
        let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: old) + #"(?![\p{L}\p{N}])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: NSRegularExpression.escapedTemplate(for: new))
    }

    // MARK: What this device wrote

    /// FNV-1a over the UTF-8 bytes: the same on every launch (`hashValue` is not).
    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100000001b3
        }
        return String(value, radix: 16)
    }

    static func writtenHash(_ id: UUID, _ defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: writtenKey) as? [String: String])?[id.uuidString]
    }

    /// The summary as the model just wrote it (or as a rename just changed it).
    static func recordWritten(_ id: UUID, summary: String?, _ defaults: UserDefaults = .standard) {
        set(summary.map(hash), for: id, key: writtenKey, defaults)
    }

    static func templateID(_ id: UUID, _ defaults: UserDefaults = .standard) -> String? {
        (defaults.dictionary(forKey: templateKey) as? [String: String])?[id.uuidString]
    }

    static func rememberTemplate(_ templateID: String, for id: UUID, _ defaults: UserDefaults = .standard) {
        set(templateID, for: id, key: templateKey, defaults)
    }

    private static func set(_ value: String?, for id: UUID, key: String, _ defaults: UserDefaults) {
        var all = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[id.uuidString] = value
        if all.count > limit {
            for extra in all.keys.filter({ $0 != id.uuidString }).prefix(all.count - limit) { all[extra] = nil }
        }
        defaults.set(all, forKey: key)
    }
}
