import CryptoKit
import Foundation

/// A record of the sync file: a JSON object as `JSONSerialization` reads it (field names and types as on
/// Android: ids as uppercase strings, times in milliseconds since 1970, nil fields left out).
typealias SyncRecord = [String: Any]

/// What the device knew about a record after the last sync: the hash of its own encoding and the hash of the
/// record as it was written to the file. A side whose hash moved since then has changed the record.
struct SyncBase: Codable, Equatable {
    var local: String
    var remote: String
}

/// Three-way merge of one collection (notes, tasks, …) between this device and the sync file. Kept free of
/// SwiftData so the same rules can run on Android (`SyncMerge.kt`).
enum SyncMerge {
    struct Local {
        let record: SyncRecord
        let updatedAt: Int64
    }

    struct Result {
        /// The collection as it goes back into the file.
        var merged: [String: SyncRecord] = [:]
        /// Records to write into the local store (new or changed elsewhere).
        var toApply: [String: SyncRecord] = [:]
        /// Local records deleted elsewhere.
        var toDelete: Set<String> = []
        /// Deleted records: id → time of deletion (ms).
        var tombstones: [String: Int64] = [:]
    }

    /// Tombstones are kept this long, so a device that was offline still learns about the deletion.
    static let tombstoneAge: Int64 = 180 * 24 * 3600 * 1000

    /// - Parameters:
    ///   - frozen: local ids left alone this time (a recording still being processed): their remote record is
    ///     kept as it is and nothing is applied or deleted.
    static func merge(
        local: [String: Local],
        remote: [String: SyncRecord],
        tombstones remoteTombstones: [String: Int64],
        base: [String: SyncBase],
        frozen: Set<String> = [],
        now: Int64
    ) -> Result {
        var result = Result()
        result.tombstones = remoteTombstones.filter { now - $0.value < tombstoneAge }
        let ids = Set(local.keys).union(remote.keys).union(base.keys)
        for id in ids {
            let l = local[id], r = remote[id], b = base[id]
            if frozen.contains(id) {
                if let r { result.merged[id] = r }
                continue
            }
            let localDirty = l.map { b == nil || hash($0.record) != b!.local } ?? false
            let remoteDirty = r.map { b == nil || hash($0) != b!.remote } ?? false
            switch (l, r) {
            case (nil, nil):
                continue
            case let (l?, nil):
                if let deletedAt = result.tombstones[id] {
                    // Deleted elsewhere; an edit here after the deletion brings it back.
                    if localDirty && l.updatedAt > deletedAt {
                        result.tombstones[id] = nil
                        result.merged[id] = l.record
                    } else {
                        result.toDelete.insert(id)
                    }
                } else {
                    // New here (or the file lost it): it goes up.
                    result.merged[id] = l.record
                }
            case let (nil, r?):
                if b != nil && !remoteDirty {
                    // Known before and gone here: deleted on this device.
                    result.tombstones[id] = now
                } else {
                    result.merged[id] = r
                    result.toApply[id] = r
                    result.tombstones[id] = nil
                }
            case let (l?, r?):
                result.tombstones[id] = nil
                let takeRemote: Bool
                switch (localDirty, remoteDirty) {
                case (false, false): takeRemote = true
                case (true, false): takeRemote = false
                case (false, true): takeRemote = true
                case (true, true): takeRemote = int64(r["updatedAt"]) > l.updatedAt
                }
                if takeRemote {
                    result.merged[id] = r
                    if remoteDirty { result.toApply[id] = r }
                } else {
                    result.merged[id] = l.record
                }
            }
        }
        return result
    }

    /// Hash of a record's canonical JSON (keys sorted).
    static func hash(_ record: SyncRecord) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func int64(_ value: Any?) -> Int64 {
        (value as? NSNumber)?.int64Value ?? 0
    }
}
