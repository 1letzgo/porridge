import CryptoKit
import Foundation
import Observation

/// The passages of all notes, ready for the chat and the search: word statistics for BM25 and a sentence
/// vector for meaning. Kept in a file of its own (not synced; it can be rebuilt from the notes at any time)
/// and only the notes that changed since the last run are cut and embedded again.
@MainActor
@Observable
final class NoteIndex {
    static let shared = NoteIndex()

    /// Goes up whenever the passages change, so views that search re-run.
    private(set) var version = 0
    /// Passages still waiting for their vector.
    private(set) var pendingEmbeddings = 0

    @ObservationIgnored private var entries: [UUID: IndexedNote] = [:]
    @ObservationIgnored private var flat: [ChatChunk] = []
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var embedTask: Task<Void, Never>?

    struct IndexedNote: Codable {
        var hash: String
        var chunks: [ChatChunk]
    }

    private struct File: Codable {
        var version: Int
        var notes: [UUID: IndexedNote]
    }

    private static let fileVersion = 1

    nonisolated private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Porridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("note-index.plist")
    }

    private init() {}

    // MARK: - Keeping up with the notes

    /// Makes the index match `notes`: new and changed notes are cut into passages (and embedded in the
    /// background), deleted ones are dropped. Cheap when nothing changed.
    func refresh(_ notes: [Note]) async {
        if !loaded { await load() }
        var changed = false
        var seen = Set<UUID>()
        for note in notes where !note.isDeleted {
            seen.insert(note.id)
            let hash = note.indexHash
            if entries[note.id]?.hash == hash { continue }
            let chunks = ChatRetrieval.chunks(from: [note])
            // Vectors of unchanged passages are kept (the note may have changed elsewhere).
            let known = Dictionary(entries[note.id]?.chunks.compactMap { chunk in chunk.embedding.map { (chunk.text, $0) } } ?? [], uniquingKeysWith: { first, _ in first })
            entries[note.id] = IndexedNote(hash: hash, chunks: chunks.map { chunk in
                var chunk = chunk
                chunk.embedding = known[chunk.text]
                return chunk
            })
            changed = true
        }
        for id in entries.keys where !seen.contains(id) {
            entries[id] = nil
            changed = true
        }
        if changed {
            rebuildFlat()
            scheduleSave()
        }
        embedMissing()
    }

    private func rebuildFlat() {
        flat = entries.values.flatMap(\.chunks)
        version += 1
    }

    /// All passages, newest note first.
    var chunks: [ChatChunk] { flat }

    // MARK: - Embeddings

    private func embedMissing() {
        let missing = flat.filter { $0.embedding == nil }
        pendingEmbeddings = missing.count
        guard !missing.isEmpty, embedTask == nil else { return }
        embedTask = Task { [weak self] in
            defer { Task { @MainActor in self?.embedTask = nil } }
            guard await TextEmbedder.shared.isAvailable else {
                await MainActor.run { self?.pendingEmbeddings = 0 }
                return
            }
            var batch: [(UUID, String, [Float])] = []
            for (i, chunk) in missing.enumerated() {
                if Task.isCancelled { return }
                if let vector = await TextEmbedder.shared.vector(for: chunk.text) {
                    batch.append((chunk.noteID, chunk.text, vector))
                }
                if batch.count >= 20 || i == missing.count - 1 {
                    let done = batch
                    batch = []
                    await MainActor.run { self?.store(done, remaining: missing.count - i - 1) }
                }
            }
        }
    }

    private func store(_ vectors: [(UUID, String, [Float])], remaining: Int) {
        for (noteID, text, vector) in vectors {
            guard var entry = entries[noteID] else { continue }
            for index in entry.chunks.indices where entry.chunks[index].text == text && entry.chunks[index].embedding == nil {
                entry.chunks[index].embedding = vector
            }
            entries[noteID] = entry
        }
        pendingEmbeddings = remaining
        rebuildFlat()
        scheduleSave()
        // Passages may have been added while this ran.
        if remaining == 0 { embedTask = nil; embedMissing() }
    }

    // MARK: - Searching

    /// The passages that fit `question` best: by words (BM25) and by meaning (vector), mixed.
    func search(_ question: String, budget: Int = 6500) async -> [ChatChunk] {
        let vector = await TextEmbedder.shared.vector(for: question)
        return ChatRetrieval.search(question, in: flat, queryVector: vector, budget: budget)
    }

    func recent(budget: Int = 4500) -> [ChatChunk] {
        ChatRetrieval.recent(from: flat, budget: budget)
    }

    /// The notes in which every word of `query` occurs (word forms count), for the list's search.
    /// Nil while the index is not loaded yet.
    func noteIDs(matching query: String) -> Set<UUID>? {
        guard loaded else { return nil }
        let words = Array(Set(ChatRetrieval.tokens(query)))
        guard !words.isEmpty else { return Set(entries.keys) }
        var result = Set<UUID>()
        for (id, entry) in entries {
            let all = words.allSatisfy { word in
                entry.chunks.contains { ChatRetrieval.frequency(word, $0) > 0 }
            }
            if all { result.insert(id) }
        }
        return result
    }

    // MARK: - File

    private func load() async {
        loaded = true
        let url = Self.fileURL
        let file: File? = await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? PropertyListDecoder().decode(File.self, from: data)
        }.value
        if let file, file.version == Self.fileVersion {
            entries = file.notes
            rebuildFlat()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = File(version: Self.fileVersion, notes: entries)
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: NoteIndex.fileURL, options: .atomic)
            }
        }
    }
}

extension Note {
    /// Changes whenever anything the passages are made of changes. Stable across launches (SHA-256).
    var indexHash: String {
        var hasher = SHA256()
        for part in [title, text, summary ?? "", pageText ?? "", url ?? "", labels.joined(separator: ","), String(createdAt.timeIntervalSince1970)] {
            hasher.update(data: Data(part.utf8))
            hasher.update(data: Data([0]))
        }
        if let segmentsData { hasher.update(data: segmentsData) }
        if let speakersData { hasher.update(data: speakersData) }
        // Links got a passage of their own (their address): their passages are cut again once.
        if url != nil { hasher.update(data: Data("link-passage".utf8)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
