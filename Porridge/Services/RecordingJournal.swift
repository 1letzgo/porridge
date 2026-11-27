import AVFoundation
import Foundation
import SwiftData

/// A safety copy of a running meeting. The m4a of a recording can only be read once it is closed, and its note is
/// made after that, so a crash or a closed app would lose all of it. This writes the sound on as it comes, plain
/// (16 kHz, mono; both channels interleaved for a split stereo recording, the Mac's sound among them, so its
/// speakers stay apart) so that every byte counts, next to what the meeting needs for a note. A normal end deletes
/// it; one still here at the next launch becomes the meeting (`recover`).
final class RecordingJournal: @unchecked Sendable {
    /// What the note is made from; in a file of its own, renewed when it changes. A copy from before the channels
    /// were kept has none of the input's fields: mono, recovered as such.
    struct Info: Codable, Equatable {
        var title: String?
        var startedAt: Date
        /// The meeting this recording continues.
        var continues: UUID?
        /// The m4a in `AudioStore` that was never closed.
        var unfinishedFile: String?
        var notes: [Note] = []
        /// Channels of the plain sound (interleaved), fixed by its first buffer; nil: 1.
        var channels: Int?
        /// The recording's input as its `RecordingResult` has it (`SystemAudioMix.inputName` with the Mac's sound).
        var inputName: String?
        var isSplitStereo: Bool?
        var includesSystemAudio: Bool?
        /// The left and the right channel's speakers of a split stereo recording, as named while recording.
        var speakerNames: [String]?

        var soundChannels: Int { channels == 2 ? 2 : 1 }

        struct Note: Codable, Equatable {
            var at: TimeInterval
            var text: String
        }
    }

    static let sampleRate = 16_000.0

    /// The plain sound's format: 16-bit, interleaved.
    static func format(channels: Int) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: true)!
    }
    /// In the data's own folder (`DataLocation`): a test run (`PORRIDGE_TEST_DATA`) keeps its copies in the test
    /// folder, so a test recording is never recovered into the real notes, nor a real one into the test data.
    private static let folder: URL = {
        let base = DataLocation.applicationSupport
        var dir = base.appendingPathComponent("Porridge/RecordingJournal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    /// The recording of this run: never taken for a leftover.
    private nonisolated(unsafe) static var activeID: UUID?
    @MainActor private static var isRecovering = false

    private let id = UUID()
    private let queue = DispatchQueue(label: "de.letzgo.porridge.journal", qos: .userInitiated)
    private var info: Info
    private var handle: FileHandle?
    private var converter: AVAudioConverter?
    /// Taken from the first buffer (`AudioRecorder.onRecordedBuffer`: two channels for a split stereo recording).
    private var soundFormat: AVAudioFormat?
    private var lastSync = Date()

    private var soundURL: URL { Self.folder.appendingPathComponent(id.uuidString).appendingPathExtension("pcm") }
    private var infoURL: URL { Self.folder.appendingPathComponent(id.uuidString).appendingPathExtension("json") }

    init(title: String?, continues: UUID? = nil) {
        info = Info(title: title, startedAt: Date(), continues: continues)
        Self.activeID = id
        FileManager.default.createFile(atPath: soundURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: soundURL)
        saveInfo()
    }

    func setUnfinishedFile(_ name: String?) {
        queue.async {
            self.info.unfinishedFile = name
            self.saveInfo()
        }
    }

    func setNotes(_ notes: [RecordingNote]) {
        let list = notes.map { Info.Note(at: $0.at, text: $0.text) }
        queue.async {
            self.info.notes = list
            self.saveInfo()
        }
    }

    /// What the recorder records (`AudioRecorder` once started): a split stereo recording is recovered as one.
    func setInput(name: String, isSplitStereo: Bool, includesSystemAudio: Bool) {
        queue.async {
            self.info.inputName = name
            self.info.isSplitStereo = isSplitStereo
            self.info.includesSystemAudio = includesSystemAudio
            self.saveInfo()
        }
    }

    /// The names of a split stereo recording's two speakers, as they would be stored on Stop.
    func setSpeakerNames(_ names: [String]) {
        queue.async {
            guard self.info.speakerNames != names else { return }
            self.info.speakerNames = names
            self.saveInfo()
        }
    }

    /// Takes a buffer from the recorder's thread (`AudioRecorder.onRecordedBuffer`): mono, or the two channels of a
    /// split stereo recording. The first one decides how many channels the copy keeps.
    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { self.write(buffer) }
    }

    /// The recording ended and has its note, or was thrown away.
    func finish() {
        queue.async {
            try? self.handle?.close()
            self.handle = nil
            try? FileManager.default.removeItem(at: self.soundURL)
            try? FileManager.default.removeItem(at: self.infoURL)
        }
        if Self.activeID == id { Self.activeID = nil }
    }

    private func saveInfo() {
        guard let data = try? JSONEncoder().encode(info) else { return }
        try? data.write(to: infoURL, options: .atomic)
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let handle else { return }
        let format: AVAudioFormat
        if let soundFormat {
            format = soundFormat
        } else {
            let channels = buffer.format.channelCount >= 2 ? 2 : 1
            format = Self.format(channels: channels)
            soundFormat = format
            if channels == 2 {
                info.channels = channels
                saveInfo()
            }
        }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var delivered = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        // A full disk only costs the safety copy, not the recording.
        try? handle.write(contentsOf: Data(bytes: samples, count: Int(out.frameLength) * 2 * Int(format.channelCount)))
        // The system holds what was written when the app ends; this is for a phone that goes off.
        if Date().timeIntervalSince(lastSync) > 10 {
            lastSync = Date()
            try? handle.synchronize()
        }
    }

    // MARK: - After a crash

    /// Makes a meeting of every recording that did not end. Too short to be a meeting: only tidied up.
    @MainActor
    static func recover(context: ModelContext, processing: ProcessingService) async {
        // A second window asks too; one pass at a time, or every leftover became two meetings.
        guard !isRecovering else { return }
        isRecovering = true
        defer { isRecovering = false }
        let active = activeID?.uuidString
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for infoURL in files where infoURL.pathExtension == "json" && infoURL.deletingPathExtension().lastPathComponent != active {
            let sound = infoURL.deletingPathExtension().appendingPathExtension("pcm")
            guard let data = try? Data(contentsOf: infoURL), let info = try? JSONDecoder().decode(Info.self, from: data) else {
                try? FileManager.default.removeItem(at: infoURL)
                try? FileManager.default.removeItem(at: sound)
                continue
            }
            let channels = info.soundChannels
            let encoded = await Task.detached(priority: .userInitiated) { Result { try encode(sound, channels: channels) } }.value
            guard case .success(let recovered) = encoded else {
                // No room or no encoder right now: the copy stays and the next launch tries again.
                print("[journal] not recovered, kept for the next launch: \(encoded)")
                continue
            }
            if let recovered, let meeting = meetingToContinue(info.continues, context: context) {
                meeting.addRecordedPart(recovered.fileName, written: info.notes.map { RecordingNote(at: $0.at, text: $0.text) })
                try? context.save()
                processing.enqueue(.note(meeting.id))
                print("[journal] recovered \(Int(recovered.duration)) s of a meeting")
            } else if let recovered {
                let note = makeNote(info, fileName: recovered.fileName, duration: recovered.duration)
                context.insert(note)
                try? context.save()
                processing.enqueue(.transcript(note.id))
                print("[journal] recovered \(Int(recovered.duration)) s")
            }
            AudioStore.delete(info.unfinishedFile)
            try? FileManager.default.removeItem(at: sound)
            try? FileManager.default.removeItem(at: infoURL)
        }
    }

    /// The meeting a copy becomes, as a normal Stop makes it: a split stereo recording (the Mac's sound among them)
    /// with its input, its channels and their two speakers, so it is transcribed per channel; mono as "Recovered".
    @MainActor
    static func makeNote(_ info: Info, fileName: String, duration: TimeInterval) -> Note {
        let note = Note()
        note.source = .meeting
        note.createdAt = info.startedAt
        note.updatedAt = info.startedAt
        note.title = info.title ?? Note.defaultMeetingTitle(for: info.startedAt)
        note.titleIsCustom = info.title != nil
        note.statusRaw = ProcessingStatus.recorded.rawValue
        note.audioFileName = fileName
        note.duration = duration
        note.channelCount = info.soundChannels
        note.inputName = info.soundChannels == 2 ? (info.inputName ?? "Recovered") : "Recovered"
        note.text = RecordingNote.markdown(info.notes.map { RecordingNote(at: $0.at, text: $0.text) })
        // Two channels are kept only for a split stereo recording (`AudioRecorder.onRecordedBuffer`).
        if info.soundChannels == 2, info.isSplitStereo != false {
            let systemAudio = info.includesSystemAudio ?? SystemAudioMix.isSystemAudio(inputName: info.inputName)
            let fallback = systemAudio ? [AppSettings.myName ?? "Me", SystemAudioMix.othersName] : ["Speaker 1", "Speaker 2"]
            let names = (0..<2).map { index in
                let name = (info.speakerNames ?? []).indices.contains(index) ? info.speakerNames![index].trimmingCharacters(in: .whitespaces) : ""
                return name.isEmpty ? fallback[index] : name
            }
            note.speakerMode = .channels
            note.speakers = [
                Speaker(id: SpeakerAssigner.leftChannelID, name: names[0], colorIndex: 0),
                Speaker(id: SpeakerAssigner.rightChannelID, name: names[1], colorIndex: 1),
            ]
        }
        return note
    }

    /// Gone or already waiting for another part: the recording becomes a meeting of its own.
    @MainActor
    private static func meetingToContinue(_ id: UUID?, context: ModelContext) -> Note? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<Note>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let meeting = try? context.fetch(descriptor).first, !meeting.isDeleted, meeting.pendingAudioFileName == nil else { return nil }
        return meeting
    }

    /// The plain sound as an m4a in `AudioStore`; nil for less than a second.
    private static func encode(_ sound: URL, channels: Int) throws -> (fileName: String, duration: TimeInterval)? {
        let name = AudioStore.newFileName()
        do {
            guard let duration = try encode(sound, channels: channels, to: AudioStore.localURL(for: name)) else { return nil }
            return (name, duration)
        } catch {
            // Half a file is no recording; the plain sound is still there for another try.
            AudioStore.delete(name)
            throw error
        }
    }

    /// The plain sound (`channels` interleaved) as an AAC file at `url` with as many channels; its duration, or nil
    /// (nothing written) for less than a second. A last frame cut off by the crash is left out.
    static func encode(_ sound: URL, channels: Int, to url: URL) throws -> TimeInterval? {
        let frameBytes = 2 * channels
        let bytes = (try FileManager.default.attributesOfItem(atPath: sound.path)[.size] as? Int) ?? 0
        guard bytes >= Int(sampleRate) * frameBytes else { return nil }
        let format = format(channels: channels)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let input = try FileHandle(forReadingFrom: sound)
        defer { try? input.close() }
        let chunk = Int(sampleRate) * frameBytes
        while let data = try input.read(upToCount: chunk), data.count >= frameBytes {
            let frames = AVAudioFrameCount(data.count / frameBytes)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw CocoaError(.fileWriteUnknown) }
            buffer.frameLength = frames
            data.withUnsafeBytes { raw in
                if let base = raw.bindMemory(to: Int16.self).baseAddress {
                    buffer.int16ChannelData?[0].update(from: base, count: Int(frames) * channels)
                }
            }
            try file.write(from: buffer)
        }
        file.close()
        return Double(bytes / frameBytes) / sampleRate
    }
}
