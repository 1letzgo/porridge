import CloudKit
import Foundation

/// The records of a shared bowl's zone, made from the store and read back into it. No network: a record is only
/// built or read here; `BowlSharing` sends and fetches them.
///
/// Record types (they have to be in the CloudKit schema, `docs/cloudkit/schema.ckdb`, deployed to Production):
/// - `SharedBowl` ("bowl"): `bowlID`, `name`.
/// - `SharedNote` ("note-<id>"): `noteID`, `updatedAt`, `payload` (the note as JSON, `SharedNotePayload`) or, when
///   that is too big for a record, `payloadAsset`.
/// - `SharedFile` ("file-<name>"): `fileName`, `kind` (`StoredFileKind`), `file` (the recording or attachment).
enum SharedBowlRecords {
    enum Field {
        static let bowlID = "bowlID"
        static let name = "name"
        static let noteID = "noteID"
        static let updatedAt = "updatedAt"
        static let payload = "payload"
        static let payloadAsset = "payloadAsset"
        static let fileName = "fileName"
        static let kind = "kind"
        static let file = "file"
    }

    /// A record may hold 1 MB in all; a bigger payload (a long transcript, a long page) goes as a file.
    static let inlinePayloadLimit = 700_000

    /// The zone SwiftData's sync keeps the notes in: never touched by the sharing.
    static let coreDataZoneName = "com.apple.coredata.cloudkit.zone"

    static func zoneID(_ info: SharedBowlInfo) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: info.zoneName, ownerName: info.zoneOwnerName)
    }

    static func recordID(_ kind: SharedBowlNames.RecordKind, in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        switch kind {
        case .bowl: CKRecord.ID(recordName: SharedBowlNames.bowlRecordName, zoneID: zoneID)
        case .note(let id): CKRecord.ID(recordName: SharedBowlNames.noteRecordName(id), zoneID: zoneID)
        case .file(let name): CKRecord.ID(recordName: SharedBowlNames.fileRecordName(name), zoneID: zoneID)
        }
    }

    static func recordType(_ kind: SharedBowlNames.RecordKind) -> CKRecord.RecordType {
        switch kind {
        case .bowl: SharedBowlNames.bowlRecordType
        case .note: SharedBowlNames.noteRecordType
        case .file: SharedBowlNames.fileRecordType
        }
    }

    // MARK: System fields

    /// The server's part of a record (its change tag among it), to send the next change on top of it.
    static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func record(fromSystemFields data: Data?) -> CKRecord? {
        guard let data, let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    /// A record to fill: the one the server knows when there is one, else a new one.
    static func base(_ kind: SharedBowlNames.RecordKind, id: CKRecord.ID, systemFields: Data?) -> CKRecord {
        if let record = record(fromSystemFields: systemFields), record.recordID == id { return record }
        return CKRecord(recordType: recordType(kind), recordID: id)
    }

    // MARK: Building

    static func fillBowl(_ record: CKRecord, bowlID: UUID, name: String) {
        record[Field.bowlID] = bowlID.uuidString
        record[Field.name] = name
    }

    /// Writes the note into the record; a big payload goes into a file in `temporaryDirectory`. Returns the
    /// fingerprint of what was written, nil when the file could not be written.
    @discardableResult
    static func fillNote(_ record: CKRecord, payload: SharedNotePayload, temporaryDirectory: URL) -> String? {
        let data = payload.encoded()
        record[Field.noteID] = payload.id.uuidString
        record[Field.updatedAt] = payload.updatedAt
        if data.count <= inlinePayloadLimit {
            record[Field.payload] = data
            record.setObject(nil, forKey: Field.payloadAsset)
        } else {
            try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            let url = temporaryDirectory.appendingPathComponent("\(payload.id.uuidString)-\(UUID().uuidString).json")
            guard (try? data.write(to: url)) != nil else { return nil }
            record[Field.payloadAsset] = CKAsset(fileURL: url)
            record.setObject(nil, forKey: Field.payload)
        }
        return SharedBowlNames.fingerprint(data)
    }

    static func fillFile(_ record: CKRecord, fileName: String, kind: StoredFileKind, url: URL) {
        record[Field.fileName] = fileName
        record[Field.kind] = kind.rawValue
        record[Field.file] = CKAsset(fileURL: url)
    }

    // MARK: Reading

    static func bowlName(of record: CKRecord) -> String {
        (record[Field.name] as? String) ?? ""
    }

    /// The note of a `SharedNote` record; nil when it cannot be read (written by a newer version, or broken).
    static func payload(of record: CKRecord) -> SharedNotePayload? {
        if let data = record[Field.payload] as? Data { return SharedNotePayload.decode(data) }
        if let asset = record[Field.payloadAsset] as? CKAsset, let url = asset.fileURL, let data = try? Data(contentsOf: url) {
            return SharedNotePayload.decode(data)
        }
        return nil
    }

    static func fileKind(of record: CKRecord) -> StoredFileKind {
        StoredFileKind(rawValue: (record[Field.kind] as? String) ?? "") ?? .attachment
    }

    static func fileURL(of record: CKRecord) -> URL? {
        (record[Field.file] as? CKAsset)?.fileURL
    }

    // MARK: The people of a share

    static func people(of share: CKShare) -> [SharedBowlPerson] {
        let current = share.currentUserParticipant
        return share.participants.compactMap { participant in
            guard participant.acceptanceStatus != .removed else { return nil }
            let identity = participant.userIdentity
            let formatted = identity.nameComponents.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
            let name = [formatted, identity.lookupInfo?.emailAddress, identity.lookupInfo?.phoneNumber]
                .compactMap { $0 }.first { !$0.isEmpty } ?? String(localized: "Someone")
            let isOwner = participant.role == .owner
            return SharedBowlPerson(
                name: name,
                isOwner: isOwner,
                isCurrentUser: current.map { $0 == participant } ?? false,
                isPending: participant.acceptanceStatus == .pending,
                canEdit: canEdit(isOwner: isOwner, permission: participant.permission),
                userRecordName: identity.userRecordID?.recordName
            )
        }
    }

    /// The owner may always edit; anyone else as the share says ("Can edit" or "Can view"); nil when it says neither.
    static func canEdit(isOwner: Bool, permission: CKShare.ParticipantPermission) -> Bool? {
        if isOwner { return true }
        switch permission {
        case .readWrite: return true
        case .readOnly: return false
        default: return nil
        }
    }

    /// Whether the share lets me only see the bowl; nil when it does not say (I am not among its people).
    static func isReadOnlyForMe(_ share: CKShare) -> Bool? {
        guard let me = share.currentUserParticipant else { return nil }
        return canEdit(isOwner: me.role == .owner, permission: me.permission).map { !$0 }
    }
}
