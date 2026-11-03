import CryptoKit
import Foundation
import Observation

/// The passages of all notes with their word statistics, for the search. Kept in a file of its own (not synced;
/// it can be rebuilt from the notes at any time) and only the notes that changed since the last run are cut again.
@MainActor
@Observable
final class NoteIndex {
    static let shared = NoteIndex()

    /// Goes up whenever the passages change, so views that search re-run.
    private(set) var version = 0

    @ObservationIgnored private var entries: [UUID: IndexedNote] = [:]
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    struct IndexedNote: Codable {
        var hash: String
        var chunks: [NoteChunk]
    }

    private struct File: Codable {
        var version: Int
        var notes: [UUID: IndexedNote]
    }

    private static let fileVersion = 2

    nonisolated private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Porridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("note-index.plist")
    }

    private init() {}

    // MARK: - Keeping up with the notes

    /// Makes the index match `notes`: new and changed notes are cut into passages, deleted ones are dropped.
    /// Cheap when nothing changed.
    func refresh(_ notes: [Note]) async {
        if !loaded { await load() }
        var changed = false
        var seen = Set<UUID>()
        for note in notes where !note.isDeleted {
            seen.insert(note.id)
            let hash = note.indexHash
            if entries[note.id]?.hash == hash { continue }
            entries[note.id] = IndexedNote(hash: hash, chunks: NoteChunks.chunks(from: [note]))
            changed = true
        }
        for id in entries.keys where !seen.contains(id) {
            entries[id] = nil
            changed = true
        }
        if changed {
            version += 1
            scheduleSave()
        }
    }

    // MARK: - Searching

    /// The notes in which every word of `query` occurs (word forms count), for the list's search.
    /// Nil while the index is not loaded yet.
    func noteIDs(matching query: String) -> Set<UUID>? {
        guard loaded else { return nil }
        let words = Array(Set(NoteChunks.tokens(query)))
        guard !words.isEmpty else { return Set(entries.keys) }
        var result = Set<UUID>()
        for (id, entry) in entries {
            let all = words.allSatisfy { word in
                entry.chunks.contains { NoteChunks.frequency(word, $0) > 0 }
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
            version += 1
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
