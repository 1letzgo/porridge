import AVFoundation
import Foundation
import SwiftData

/// A safety copy of a running meeting. The m4a of a recording can only be read once it is closed, and its note is
/// made after that, so a crash or a closed app would lose all of it. This writes the sound on as it comes, plain
/// (16 kHz mono) so that every byte counts, next to what the meeting needs for a note. A normal end deletes it;
/// one still here at the next launch becomes the meeting (`recover`).
final class RecordingJournal: @unchecked Sendable {
    /// What the note is made from; in a file of its own, renewed when it changes.
    private struct Info: Codable {
        var title: String?
        var startedAt: Date
        /// The meeting this recording continues.
        var continues: UUID?
        /// The m4a in `AudioStore` that was never closed.
        var unfinishedFile: String?
        var notes: [Note] = []

        struct Note: Codable {
            var at: TimeInterval
            var text: String
        }
    }

    private static let sampleRate = 16_000.0
    private static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    private static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Porridge/RecordingJournal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    /// The recording of this run: never taken for a leftover.
    private nonisolated(unsafe) static var activeID: UUID?

    private let id = UUID()
    private let queue = DispatchQueue(label: "de.letzgo.porridge.journal", qos: .userInitiated)
    private var info: Info
    private var handle: FileHandle?
    private var converter: AVAudioConverter?
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

    /// Takes a mono buffer from the recorder's thread.
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
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: Self.format)
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
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
        try? handle.write(contentsOf: Data(bytes: samples, count: Int(out.frameLength) * 2))
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
        let active = activeID?.uuidString
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for infoURL in files where infoURL.pathExtension == "json" && infoURL.deletingPathExtension().lastPathComponent != active {
            let sound = infoURL.deletingPathExtension().appendingPathExtension("pcm")
            guard let data = try? Data(contentsOf: infoURL), let info = try? JSONDecoder().decode(Info.self, from: data) else {
                try? FileManager.default.removeItem(at: infoURL)
                try? FileManager.default.removeItem(at: sound)
                continue
            }
            let recovered = await Task.detached(priority: .userInitiated) { try? encode(sound) }.value
            if let recovered, let meeting = meetingToContinue(info.continues, context: context) {
                meeting.addRecordedPart(recovered.fileName, written: info.notes.map { RecordingNote(at: $0.at, text: $0.text) })
                try? context.save()
                processing.enqueue(.note(meeting.id))
                print("[journal] recovered \(Int(recovered.duration)) s of a meeting")
            } else if let recovered {
                let note = Note()
                note.createdAt = info.startedAt
                note.updatedAt = info.startedAt
                note.title = info.title ?? Note.defaultMeetingTitle(for: info.startedAt)
                note.titleIsCustom = info.title != nil
                note.statusRaw = ProcessingStatus.recorded.rawValue
                note.audioFileName = recovered.fileName
                note.duration = recovered.duration
                note.channelCount = 1
                note.inputName = "Recovered"
                note.text = RecordingNote.markdown(info.notes.map { RecordingNote(at: $0.at, text: $0.text) })
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
    private static func encode(_ sound: URL) throws -> (fileName: String, duration: TimeInterval)? {
        let bytes = (try FileManager.default.attributesOfItem(atPath: sound.path)[.size] as? Int) ?? 0
        guard bytes >= Int(sampleRate) * 2 else { return nil }
        let name = AudioStore.newFileName()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let file = try AVAudioFile(forWriting: AudioStore.url(for: name), settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let input = try FileHandle(forReadingFrom: sound)
        defer { try? input.close() }
        let chunk = Int(sampleRate) * 2
        while let data = try input.read(upToCount: chunk), !data.isEmpty {
            let frames = AVAudioFrameCount(data.count / 2)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
            buffer.frameLength = frames
            data.withUnsafeBytes { raw in
                buffer.int16ChannelData?[0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: Int(frames))
            }
            try file.write(from: buffer)
        }
        file.close()
        return (name, Double(bytes / 2) / sampleRate)
    }
}
