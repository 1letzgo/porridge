import Accelerate
import Foundation

/// The entries most like one entry, from the search index on the device (`NoteIndex`): each entry's passages as one
/// vector (`TextEmbedder`), compared by cosine. Entries without vectors yet (the model still embedding, or not
/// available) are compared by their words instead. Nothing leaves the device; nothing is stored.
@MainActor
enum SimilarEntries {
    /// What an entry is about: the mean of its passages' vectors, and its words.
    struct Profile: Equatable {
        var vector: [Float]?
        var words: Set<String>
    }

    struct Match: Equatable {
        let id: UUID
        let score: Float
    }

    /// The passages that say what an entry is about. A to-do's state and a link's address say nothing of the
    /// content: two to-dos would look alike for being to-dos.
    nonisolated static let contentParts: Set<ChatChunk.Part> = [.title, .summary, .text, .page, .transcript, .files]

    /// Words every entry of a kind has (the labels in front of passages), and short common words.
    nonisolated static let ignoredWords: Set<String> = [
        "summary", "transcript", "article", "text", "file", "image", "document", "saved", "link", "the", "and", "der", "die", "das",
        "und", "ist", "mit", "for", "von", "den", "dem", "ein", "eine", "nicht", "auch", "sich", "that", "this", "with", "are", "was",
    ]

    /// At least this cosine (of the centered vectors) to count as similar.
    nonisolated static let minimumVectorScore: Float = 0.2
    /// At least this share of words in common (Jaccard), and at least `minimumSharedWords` of them, without vectors.
    nonisolated static let minimumWordScore: Float = 0.08
    nonisolated static let minimumSharedWords = 3

    // MARK: Profiles

    /// The profile of every entry with content. The vectors are centered on their mean before they are compared:
    /// sentence vectors all point roughly the same way, and what is common to every entry says nothing about two.
    nonisolated static func profiles(from chunks: [UUID: [ChatChunk]]) -> [UUID: Profile] {
        var means: [UUID: [Float]] = [:]
        var words: [UUID: Set<String>] = [:]
        for (id, passages) in chunks {
            let content = passages.filter { contentParts.contains($0.part) }
            guard !content.isEmpty else { continue }
            var set = Set<String>()
            for chunk in content {
                for word in chunk.frequencies.keys where word.count >= 3 && !ignoredWords.contains(word) && !word.allSatisfy(\.isNumber) {
                    set.insert(word)
                }
            }
            words[id] = set
            let vectors = content.compactMap(\.embedding)
            guard let first = vectors.first else { continue }
            var sum = [Float](repeating: 0, count: first.count)
            var count = 0
            for vector in vectors where vector.count == sum.count {
                vDSP.add(sum, vector, result: &sum)
                count += 1
            }
            if count > 0 { means[id] = vDSP.divide(sum, Float(count)) }
        }
        // The center of all entries.
        var center: [Float]?
        if let dimension = means.values.first?.count {
            var sum = [Float](repeating: 0, count: dimension)
            var count = 0
            for vector in means.values where vector.count == dimension {
                vDSP.add(sum, vector, result: &sum)
                count += 1
            }
            // With one or two entries there is nothing to center on.
            if count >= 3 { center = vDSP.divide(sum, Float(count)) }
        }
        var result: [UUID: Profile] = [:]
        for (id, set) in words {
            var vector = means[id]
            if let mean = vector {
                var shifted = center.map { mean.count == $0.count ? vDSP.subtract(mean, $0) : mean } ?? mean
                let norm = sqrt(vDSP.dot(shifted, shifted))
                if norm > 0 {
                    vDSP.divide(shifted, norm, result: &shifted)
                    vector = shifted
                } else {
                    vector = nil
                }
            }
            result[id] = Profile(vector: vector, words: set)
        }
        return result
    }

    // MARK: Choosing

    /// The `limit` entries most like `id`, best first. Left out: the entry itself, those in `excluding`, and those
    /// that are only a little alike. Vectors where both have one, else words in common.
    nonisolated static func select(for id: UUID, in profiles: [UUID: Profile], excluding: Set<UUID> = [], limit: Int = 5) -> [Match] {
        guard let target = profiles[id], limit > 0 else { return [] }
        var matches: [Match] = []
        for (other, profile) in profiles where other != id && !excluding.contains(other) {
            if let a = target.vector, let b = profile.vector, a.count == b.count {
                let score = vDSP.dot(a, b)
                if score >= minimumVectorScore { matches.append(Match(id: other, score: score)) }
            } else {
                let shared = target.words.intersection(profile.words).count
                guard shared >= minimumSharedWords else { continue }
                let score = Float(shared) / Float(target.words.union(profile.words).count)
                if score >= minimumWordScore { matches.append(Match(id: other, score: score)) }
            }
        }
        // The same order every time, also for equal scores.
        matches.sort { $0.score != $1.score ? $0.score > $1.score : $0.id.uuidString < $1.id.uuidString }
        return Array(matches.prefix(limit))
    }

    // MARK: In the app

    private static var cache: (version: Int, profiles: [UUID: Profile])?

    /// The entries most like `note` among `notes`, from the index as it is now. Cheap after the first call for an
    /// index version: the profiles are kept until the index changes.
    static func similar(to note: Note, among notes: [Note], index: NoteIndex = .shared, limit: Int = 5) -> [Note] {
        let profiles: [UUID: Profile]
        if let cache, cache.version == index.version {
            profiles = cache.profiles
        } else {
            profiles = Self.profiles(from: index.chunksByNote)
            cache = (index.version, profiles)
        }
        guard profiles[note.id] != nil else { return [] }
        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Entries the index still has but the store no longer does are skipped (asks for a few more).
        let matches = select(for: note.id, in: profiles, excluding: excluded(for: note, among: notes), limit: limit + 5)
        return matches.compactMap { byID[$0.id] }.prefix(limit).map { $0 }
    }

    /// The trivial matches of `note`: entries in the trash, and those linked to it already (the note a to-do was
    /// made from, the to-dos made from this one), which its page shows anyway.
    static func excluded(for note: Note, among notes: [Note]) -> Set<UUID> {
        var result = Set<UUID>()
        if let source = note.todoSourceID.flatMap(UUID.init(uuidString:)) { result.insert(source) }
        let own = note.id.uuidString
        for other in notes where other.todoSourceID == own || other.isDeleted { result.insert(other.id) }
        result.remove(note.id)
        return result
    }
}
