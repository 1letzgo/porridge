import Foundation

/// The models as records of the sync file and back. Field names and types are those of the Android app's
/// JSON (`kotlinx.serialization` of its Room entities), so both read the same file.
enum SyncRecords {
    // MARK: Note

    static func record(_ note: Note) -> SyncRecord {
        var r: SyncRecord = [
            "id": note.id.uuidString,
            "title": note.title,
            "text": note.text,
            "createdAt": ms(note.createdAt),
            "updatedAt": ms(note.updatedAt),
            "statusRaw": note.statusRaw,
            "audioFileNames": note.audioFileNames,
            "isPinned": note.isPinned,
            "labels": note.labels,
            "titleIsCustom": note.titleIsCustom,
            "duration": note.duration,
            "channelCount": note.channelCount,
            "speakerModeRaw": note.speakerModeRaw,
        ]
        r["errorMessage"] = note.errorMessage
        r["pendingAudioFileName"] = note.pendingAudioFileName
        r["folderID"] = note.folderID?.uuidString
        r["deletedAt"] = note.deletedAt.map { ms($0) }
        r["url"] = note.url
        r["pageText"] = note.pageText
        r["summary"] = note.summary
        r["summaryModel"] = note.summaryModel
        r["summarizedAt"] = note.summarizedAt.map { ms($0) }
        r["inputName"] = note.inputName
        r["audioFileName"] = note.audioFileName
        r["speakersData"] = note.speakersData.flatMap { String(data: $0, encoding: .utf8) }
        r["segmentsData"] = note.segmentsData.flatMap { String(data: $0, encoding: .utf8) }
        return r
    }

    static func apply(_ r: SyncRecord, to note: Note) {
        note.title = r["title"] as? String ?? ""
        note.text = r["text"] as? String ?? ""
        note.createdAt = date(r["createdAt"]) ?? note.createdAt
        note.updatedAt = date(r["updatedAt"]) ?? note.updatedAt
        note.statusRaw = r["statusRaw"] as? String ?? ProcessingStatus.ready.rawValue
        note.errorMessage = r["errorMessage"] as? String
        note.pendingAudioFileName = r["pendingAudioFileName"] as? String
        note.audioFileNames = r["audioFileNames"] as? [String] ?? []
        note.folderID = uuid(r["folderID"])
        note.isPinned = r["isPinned"] as? Bool ?? false
        note.deletedAt = date(r["deletedAt"])
        note.url = r["url"] as? String
        note.pageText = r["pageText"] as? String
        note.labels = r["labels"] as? [String] ?? []
        note.summary = r["summary"] as? String
        note.summaryModel = r["summaryModel"] as? String
        note.summarizedAt = date(r["summarizedAt"])
        note.titleIsCustom = r["titleIsCustom"] as? Bool ?? false
        note.duration = (r["duration"] as? NSNumber)?.doubleValue ?? 0
        note.inputName = r["inputName"] as? String
        note.channelCount = (r["channelCount"] as? NSNumber)?.intValue ?? 1
        note.speakerModeRaw = r["speakerModeRaw"] as? String ?? SpeakerMode.none.rawValue
        note.audioFileName = r["audioFileName"] as? String
        note.speakersData = (r["speakersData"] as? String).map { Data($0.utf8) }
        note.segmentsData = (r["segmentsData"] as? String).map { Data($0.utf8) }
    }

    /// A recording still on its way to a transcript stays on this device until it is done.
    static func isFrozen(_ note: Note) -> Bool {
        note.pendingAudioFileName != nil || note.status == .recorded || note.status == .transcribing
    }

    /// The recordings a note points at.
    static func audioFiles(_ r: SyncRecord) -> [String] {
        [r["audioFileName"] as? String].compactMap { $0 } + (r["audioFileNames"] as? [String] ?? [])
    }

    // MARK: ActionItem

    static func record(_ item: ActionItem) -> SyncRecord {
        var r: SyncRecord = [
            "id": item.id.uuidString,
            "kindRaw": item.kindRaw,
            "text": item.text,
            "isDone": item.isDone,
            "createdAt": ms(item.createdAt),
            "order": item.order,
            "source": item.source,
            "details": item.details,
            "updatedAt": ms(item.updatedAt),
            "reviewRaw": item.reviewRaw,
        ]
        r["noteID"] = item.noteID?.uuidString
        r["owner"] = item.owner
        r["doneAt"] = item.doneAt.map { ms($0) }
        r["summaryKey"] = item.summaryKey
        return r
    }

    static func apply(_ r: SyncRecord, to item: ActionItem) {
        item.noteID = uuid(r["noteID"])
        item.kindRaw = r["kindRaw"] as? String ?? ActionItem.Kind.task.rawValue
        item.text = r["text"] as? String ?? ""
        item.owner = r["owner"] as? String
        item.isDone = r["isDone"] as? Bool ?? false
        item.doneAt = date(r["doneAt"])
        item.createdAt = date(r["createdAt"]) ?? item.createdAt
        item.order = (r["order"] as? NSNumber)?.intValue ?? 0
        item.source = r["source"] as? String ?? "summary"
        item.details = r["details"] as? String ?? ""
        item.summaryKey = r["summaryKey"] as? String
        item.updatedAt = date(r["updatedAt"]) ?? item.updatedAt
        item.reviewRaw = r["reviewRaw"] as? String ?? ActionItem.Review.accepted.rawValue
    }

    // MARK: NoteFolder

    static func record(_ folder: NoteFolder) -> SyncRecord {
        var r: SyncRecord = ["id": folder.id.uuidString, "name": folder.name, "createdAt": ms(folder.createdAt)]
        r["parentID"] = folder.parentID?.uuidString
        return r
    }

    static func apply(_ r: SyncRecord, to folder: NoteFolder) {
        folder.name = r["name"] as? String ?? ""
        folder.createdAt = date(r["createdAt"]) ?? folder.createdAt
        folder.parentID = uuid(r["parentID"])
    }

    // MARK: VoiceProfile

    /// Voice prints come from a different model on Android and are not interchangeable: each platform keeps
    /// its own list in the file (`voiceProfilesApple`).
    static func record(_ profile: VoiceProfile) -> SyncRecord {
        [
            "id": profile.id.uuidString,
            "name": profile.name,
            "voiceData": profile.voiceData.base64EncodedString(),
            "seconds": profile.seconds,
            "updatedAt": ms(profile.updatedAt),
        ]
    }

    static func apply(_ r: SyncRecord, to profile: VoiceProfile) {
        profile.name = r["name"] as? String ?? ""
        profile.voiceData = (r["voiceData"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
        profile.seconds = (r["seconds"] as? NSNumber)?.doubleValue ?? 0
        profile.updatedAt = date(r["updatedAt"]) ?? profile.updatedAt
    }

    // MARK: Values

    static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    static func date(_ value: Any?) -> Date? {
        (value as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
    }

    static func uuid(_ value: Any?) -> UUID? {
        (value as? String).flatMap(UUID.init(uuidString:))
    }
}
