import AVFoundation
import Foundation
import SwiftData

/// Combines several recorded notes into one: transcripts in time order, speakers matched up, recordings joined.
@MainActor
enum NoteMerger {
    enum MergeError: LocalizedError {
        case audio

        var errorDescription: String? {
            switch self {
            case .audio: "The recordings could not be combined."
            }
        }
    }

    private static let defaultNamePrefix = "Speaker "

    /// Merges `others` into `base`; `base` keeps its title and the others are deleted.
    static func merge(_ others: [Note], into base: Note, context: ModelContext) async throws {
        let ordered = ([base] + others).sorted { $0.createdAt < $1.createdAt }

        // The recordings come first: the joined audio decides where each transcript starts.
        let oldAudio = ordered.compactMap(\.audioFileName)
        var mergedAudio: String?
        var offsets: [Double] = []
        var total = 0.0
        if ordered.allSatisfy(\.hasLocalAudio) {
            let joined = try await concatenate(oldAudio.map(AudioStore.url(for:)))
            mergedAudio = joined.fileName
            offsets = joined.offsets
            total = joined.duration
        } else {
            for meeting in ordered {
                offsets.append(total)
                total += max(meeting.duration, meeting.segments.last?.end ?? 0)
            }
        }

        // Speakers: the same person (profile, name or voice) becomes one speaker.
        var speakers: [Speaker] = []
        var segments: [TranscriptSegment] = []
        for (index, meeting) in ordered.enumerated() {
            var idMap: [String: String] = [:]
            for speaker in meeting.speakers {
                if let match = speakers.firstIndex(where: { isSamePerson($0, speaker) }) {
                    idMap[speaker.id] = speakers[match].id
                    if speakers[match].voice == nil {
                        speakers[match].voice = speaker.voice
                        speakers[match].voiceSeconds = speaker.voiceSeconds
                    }
                    if speakers[match].profileID == nil { speakers[match].profileID = speaker.profileID }
                } else {
                    var copy = speaker
                    copy.id = "m\(speakers.count + 1)"
                    copy.colorIndex = speakers.count
                    speakers.append(copy)
                    idMap[speaker.id] = copy.id
                }
            }
            for var segment in meeting.segments {
                segment.start += offsets[index]
                segment.end += offsets[index]
                segment.speakerId = segment.speakerId.flatMap { idMap[$0] }
                segments.append(segment)
            }
        }
        // Several unnamed speakers from different meetings would all be called "Speaker 1".
        var number = 1
        for index in speakers.indices where speakers[index].name.hasPrefix(defaultNamePrefix) && speakers[index].profileID == nil {
            speakers[index].name = "\(defaultNamePrefix)\(number)"
            number += 1
        }

        // Old recordings are only deleted after everything above worked.
        oldAudio.forEach(AudioStore.delete)
        base.audioFileName = mergedAudio
        if let mergedAudio, let info = AudioStore.audioInfo(for: mergedAudio) {
            base.channelCount = info.channels
        }

        base.createdAt = ordered[0].createdAt
        // The notes' own texts are joined in time order too.
        base.text = ordered.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        base.updatedAt = Date()
        base.duration = total
        base.segments = segments
        base.speakers = speakers
        base.speakerMode = speakers.isEmpty ? .none : .diarized
        base.summary = nil
        base.summaryModel = nil
        base.summarizedAt = nil
        base.errorMessage = nil
        base.status = .ready

        for meeting in others { NoteStore.deletePermanently(meeting, in: context) }
        try? context.save()
    }

    private static func isSamePerson(_ a: Speaker, _ b: Speaker) -> Bool {
        if let pa = a.profileID, let pb = b.profileID { return pa == pb }
        let aNamed = !a.name.hasPrefix(defaultNamePrefix)
        let bNamed = !b.name.hasPrefix(defaultNamePrefix)
        if aNamed, bNamed { return a.name.caseInsensitiveCompare(b.name) == .orderedSame }
        // At least one is unnamed: compare voices.
        guard let da = a.voice, let db = b.voice else { return false }
        return VoiceMath.cosine(VoiceMath.floats(from: da), VoiceMath.floats(from: db)) >= VoiceProfiles.matchThreshold
    }

    /// Joins the recordings one after another into a new file. `offsets` are the start times of each part.
    private static func concatenate(_ urls: [URL]) async throws -> (fileName: String, offsets: [Double], duration: Double) {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MergeError.audio
        }
        var cursor = CMTime.zero
        var offsets: [Double] = []
        for url in urls {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { throw MergeError.audio }
            offsets.append(cursor.seconds)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            cursor = CMTimeAdd(cursor, duration)
        }

        let name = AudioStore.newFileName()
        let output = AudioStore.url(for: name)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw MergeError.audio
        }
        do {
            try await export.export(to: output, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw MergeError.audio
        }
        return (name, offsets, cursor.seconds)
    }
}
