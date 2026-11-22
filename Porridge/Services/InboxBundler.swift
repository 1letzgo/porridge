import Foundation
import SwiftData

/// "These 4 entries belong together: a new bowl 'Garden'?" One suggestion at a time, shown on top of the Inbox.
/// Entries are grouped by meaning with the vectors the search already has (`NoteIndex`, `TextEmbedder`), or, where
/// there are none, by a tag they share. Entries that already have a bowl suggested (`Note.suggestedProjectIDs`) have
/// a place to go and are left out. A suggestion that was dismissed is not shown again (on this device).
struct InboxBundle: Equatable {
    var noteIDs: [UUID]
    var name: String
    /// An active bowl has that name already: the entries would go into it.
    var isExistingBowl = false

    /// The same group, whatever the order.
    var key: String { noteIDs.map(\.uuidString).sorted().joined(separator: ",") }
}

enum InboxBundler {
    static let minimumSize = 3
    static let maximumSize = 12
    /// Cosine two entries need, after the vectors were centered on the inbox's mean (what all entries share is
    /// taken out, so that only what sets them apart counts).
    static let centeredThreshold: Float = 0.45
    /// Without enough entries to center on, the raw cosine of the sentence vectors, which is high for any text.
    static let rawThreshold: Float = 0.9
    /// Centering needs some entries to know what they share.
    static let minimumForCentering = 6
    /// Only the newest entries are looked at: the grouping grows with the square of their number and more.
    static let maximumLookedAt = 150

    // MARK: Grouping

    /// Groups of entries whose vectors are close, the largest first; each entry in one group at most.
    static func clusters(_ vectors: [UUID: [Float]]) -> [[UUID]] {
        let ids = vectors.keys.sorted { $0.uuidString < $1.uuidString }
        guard ids.count >= minimumSize else { return [] }
        let centered = ids.count >= minimumForCentering
        let threshold = centered ? centeredThreshold : rawThreshold
        let list = centered ? center(ids.map { vectors[$0]! }) : ids.map { vectors[$0]! }
        let n = ids.count
        var sim = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let s = TextEmbedder.similarity(list[i], list[j])
                sim[i][j] = s
                sim[j][i] = s
            }
        }
        var free = Set(0..<n)
        var result: [[UUID]] = []
        while true {
            // The entry with the most close neighbours still free is the seed.
            let neighbours = free.map { i in (i, free.filter { $0 != i && sim[i][$0] >= threshold }) }
            guard let best = neighbours.max(by: { a, b in a.1.count != b.1.count ? a.1.count < b.1.count : a.0 > b.0 }),
                  best.1.count + 1 >= minimumSize else { break }
            let seed = best.0, near = best.1
            var members = Set(near).union([seed])
            // Members that are close to the seed but not to the rest leave, the weakest first.
            while members.count >= minimumSize {
                let mean = members.map { i in (i, members.filter { $0 != i }.map { sim[i][$0] }.reduce(0, +) / Float(members.count - 1)) }
                guard let weakest = mean.min(by: { $0.1 < $1.1 }), weakest.1 < threshold * 0.85 else { break }
                members.remove(weakest.0)
            }
            if members.count > maximumSize {
                members = Set(members.filter { $0 != seed }.sorted { sim[seed][$0] > sim[seed][$1] }.prefix(maximumSize - 1))
                members.insert(seed)
            }
            free.subtract(members)
            free.remove(seed)
            if members.count >= minimumSize {
                result.append(members.sorted().map { ids[$0] })
            }
        }
        return result
    }

    /// The vectors less their mean, normalized again.
    static func center(_ vectors: [[Float]]) -> [[Float]] {
        guard let first = vectors.first else { return [] }
        var mean = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == mean.count {
            for k in mean.indices { mean[k] += v[k] }
        }
        for k in mean.indices { mean[k] /= Float(vectors.count) }
        return vectors.map { v in
            guard v.count == mean.count else { return v }
            var d = zip(v, mean).map { $0 - $1 }
            let norm = sqrt(d.reduce(0) { $0 + $1 * $1 })
            if norm > 0 { d = d.map { $0 / norm } }
            return d
        }
    }

    /// Groups of at least `minimumSize` entries sharing a tag, the largest first; each entry in one group at most.
    static func tagGroups(_ notes: [(id: UUID, tags: [String])]) -> [(tag: String, ids: [UUID])] {
        var byTag: [String: (tag: String, ids: [UUID])] = [:]
        for note in notes {
            for tag in note.tags {
                let key = tag.lowercased()
                byTag[key, default: (tag, [])].ids.append(note.id)
            }
        }
        var used = Set<UUID>()
        var result: [(String, [UUID])] = []
        for group in byTag.values.sorted(by: { $0.ids.count != $1.ids.count ? $0.ids.count > $1.ids.count : $0.tag < $1.tag }) {
            let ids = group.ids.filter { !used.contains($0) }
            guard ids.count >= minimumSize else { continue }
            let chosen = Array(ids.prefix(maximumSize))
            used.formUnion(chosen)
            result.append((group.tag, chosen))
        }
        return result
    }

    // MARK: Naming

    private static let stopwords: Set<String> = [
        "the", "and", "for", "with", "from", "this", "that", "about", "into", "your", "have", "will", "what", "when", "note",
        "notes", "meeting", "der", "die", "das", "und", "mit", "für", "von", "auf", "ist", "ein", "eine", "einen", "dem", "den",
        "des", "sich", "nicht", "auch", "noch", "aber", "oder", "wie", "was", "bei", "aus", "nach", "über", "unter", "heute",
        "morgen", "notiz", "termin", "empty", "new",
    ]

    /// A name for the group: a tag most of them share; else a word most of their titles share; else "New Bowl".
    static func name(for notes: [(title: String, tags: [String])]) -> String {
        let half = max(2, (notes.count + 1) / 2)
        var tagCount: [String: (String, Int)] = [:]
        for note in notes {
            for tag in Set(note.tags.map { $0.lowercased() }) {
                let original = note.tags.first { $0.lowercased() == tag } ?? tag
                tagCount[tag, default: (original, 0)].1 += 1
            }
        }
        if let best = tagCount.values.filter({ $0.1 >= half }).max(by: { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 > $1.0 }) {
            return capitalized(best.0.replacingOccurrences(of: "-", with: " "))
        }
        var wordCount: [String: Int] = [:]
        for note in notes {
            let words = Set(note.title.lowercased()
                .components(separatedBy: CharacterSet.letters.inverted)
                .filter { $0.count >= 3 && !stopwords.contains($0) })
            for word in words { wordCount[word, default: 0] += 1 }
        }
        if let best = wordCount.filter({ $0.value >= half }).max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
            return capitalized(best.key)
        }
        return "New Bowl"
    }

    private static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    // MARK: Dismissed (on this device only)

    static let dismissedKey = "inboxBundler.dismissed"

    /// A group counts as dismissed when it is mostly one that was dismissed before (more than half of either).
    static func isDismissed(_ ids: [UUID], dismissed: [[String]]) -> Bool {
        let mine = Set(ids.map(\.uuidString))
        return dismissed.contains { old in
            let other = Set(old)
            let shared = mine.intersection(other).count
            return shared * 2 > mine.count || shared * 2 > other.count
        }
    }

    static func dismissedGroups(_ defaults: UserDefaults = .standard) -> [[String]] {
        (defaults.array(forKey: dismissedKey) as? [[String]]) ?? []
    }

    static func dismiss(_ bundle: InboxBundle, defaults: UserDefaults = .standard) {
        var all = dismissedGroups(defaults)
        all.append(bundle.noteIDs.map(\.uuidString).sorted())
        // The oldest go once there are many: their entries left the inbox long ago.
        if all.count > 200 { all.removeFirst(all.count - 200) }
        defaults.set(all, forKey: dismissedKey)
    }

    // MARK: The suggestion

    /// The entries that may be grouped: in the inbox, the user's or saved, with something in them, and no bowl
    /// suggested for them already.
    static func eligible(_ notes: [Note]) -> [Note] {
        Array(notes.filter { $0.isInInbox && $0.suggestedProjectIDs.isEmpty && !$0.isEmptyLeftover }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(maximumLookedAt))
    }

    /// The one suggestion to show: the first group by meaning, else by tag, that was not dismissed.
    static func suggestion(inbox notes: [Note], vectors: [UUID: [Float]], dismissed: [[String]], existingNames: [String] = []) -> InboxBundle? {
        let candidates = eligible(notes)
        guard candidates.count >= minimumSize else { return nil }
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let usable = vectors.filter { byID[$0.key] != nil }
        for group in clusters(usable) where !isDismissed(group, dismissed: dismissed) {
            let members = group.compactMap { byID[$0] }
            let ordered = members.sorted { $0.createdAt > $1.createdAt }
            return bundle(ordered.map(\.id), name: name(for: ordered.map { ($0.displayTitle, $0.tags) }), existingNames: existingNames)
        }
        for group in tagGroups(candidates.map { ($0.id, $0.tags) }) where !isDismissed(group.ids, dismissed: dismissed) {
            let ordered = group.ids.compactMap { byID[$0] }.sorted { $0.createdAt > $1.createdAt }
            return bundle(ordered.map(\.id), name: capitalized(group.tag.replacingOccurrences(of: "-", with: " ")), existingNames: existingNames)
        }
        return nil
    }

    private static func bundle(_ ids: [UUID], name: String, existingNames: [String]) -> InboxBundle {
        let existing = existingNames.contains { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        return InboxBundle(noteIDs: ids, name: name, isExistingBowl: existing)
    }
}

@MainActor
extension InboxBundler {
    /// One vector per entry: the mean of its passages' vectors in the search index, normalized. Entries whose
    /// passages have no vector yet are left out.
    static func vectors(for ids: Set<UUID>, index: NoteIndex = .shared) -> [UUID: [Float]] {
        var sums: [UUID: [Float]] = [:]
        for chunk in index.chunks where ids.contains(chunk.noteID) {
            guard let vector = chunk.embedding else { continue }
            if let sum = sums[chunk.noteID], sum.count == vector.count {
                sums[chunk.noteID] = zip(sum, vector).map(+)
            } else if sums[chunk.noteID] == nil {
                sums[chunk.noteID] = vector
            }
        }
        return sums.mapValues { v in
            let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
            return norm > 0 ? v.map { $0 / norm } : v
        }
    }

    /// The suggestion for the inbox now, from what the search index holds.
    static func current(_ notes: [Note], projects: [NoteFolder]) -> InboxBundle? {
        let inbox = eligible(notes)
        guard inbox.count >= minimumSize else { return nil }
        return suggestion(
            inbox: inbox, vectors: vectors(for: Set(inbox.map(\.id))), dismissed: dismissedGroups(),
            existingNames: projects.filter { !$0.isArchived && !BowlSharing.shared.isReadOnly($0.id) }.map(\.name)
        )
    }

    /// Makes the bowl (or takes the active one of that name) and moves the chosen entries into it.
    static func apply(name: String, noteIDs: [UUID], notes: [Note], in context: ModelContext) -> BowlChange? {
        // Still in the inbox, and not meanwhile in a bowl shared with me to view only.
        let chosen = noteIDs.compactMap { id in notes.first { $0.id == id } }
            .filter { !$0.isDeleted && $0.isInInbox && !BowlSharing.shared.isReadOnly($0) }
        guard !chosen.isEmpty, let found = BowlMaking.findOrCreate(name, in: context) else { return nil }
        let moved = chosen.map { BowlMaking.move($0, into: found.bowl, in: context) }
        try? context.save()
        return BowlChange(bowlID: found.bowl.id, bowlName: found.bowl.name, createdBowl: found.created, createdNoteIDs: [], moved: moved)
    }
}
