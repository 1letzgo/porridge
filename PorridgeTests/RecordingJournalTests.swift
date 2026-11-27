import AVFoundation
import XCTest
@testable import Porridge

/// The safety copy of a running recording: what it notes about the input, and the meeting a split stereo copy
/// becomes after a crash (both channels, the speakers per channel), with an old mono copy recovered as before.
final class RecordingJournalTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: What is noted

    func testInputIsWrittenAndReadBack() throws {
        var info = RecordingJournal.Info(title: "Call", startedAt: Date(timeIntervalSince1970: 1_000), continues: nil)
        info.channels = 2
        info.inputName = SystemAudioMix.inputName
        info.isSplitStereo = true
        info.includesSystemAudio = true
        info.speakerNames = ["Dana", "Others"]
        let read = try JSONDecoder().decode(RecordingJournal.Info.self, from: JSONEncoder().encode(info))
        XCTAssertEqual(read, info)
        XCTAssertEqual(read.soundChannels, 2)
    }

    func testAnOldCopyIsMono() throws {
        let json = #"{"title":"Old","startedAt":0,"notes":[{"at":3,"text":"Hi"}]}"#
        let info = try JSONDecoder().decode(RecordingJournal.Info.self, from: Data(json.utf8))
        XCTAssertNil(info.channels)
        XCTAssertNil(info.inputName)
        XCTAssertEqual(info.soundChannels, 1)
        XCTAssertEqual(info.notes.first?.text, "Hi")
    }

    // MARK: The meeting it becomes

    @MainActor
    func testACopyWithTheMacsSoundIsRecoveredPerChannel() {
        var info = RecordingJournal.Info(title: "Call", startedAt: Date(), continues: nil)
        info.channels = 2
        info.inputName = SystemAudioMix.inputName
        info.isSplitStereo = true
        info.includesSystemAudio = true
        info.speakerNames = ["Dana", "Others"]
        let note = RecordingJournal.makeNote(info, fileName: "a.m4a", duration: 41)
        XCTAssertEqual(note.channelCount, 2)
        XCTAssertEqual(note.inputName, SystemAudioMix.inputName)
        XCTAssertTrue(SystemAudioMix.isSystemAudio(inputName: note.inputName))
        XCTAssertEqual(note.speakerMode, .channels)
        XCTAssertEqual(note.speakers, [
            Speaker(id: SpeakerAssigner.leftChannelID, name: "Dana", colorIndex: 0),
            Speaker(id: SpeakerAssigner.rightChannelID, name: "Others", colorIndex: 1),
        ])
        XCTAssertEqual(note.duration, 41)
        XCTAssertEqual(note.audioFileName, "a.m4a")
    }

    @MainActor
    func testWithoutNamesTheMacsSoundIsOthers() {
        var info = RecordingJournal.Info(title: nil, startedAt: Date(), continues: nil)
        info.channels = 2
        info.inputName = SystemAudioMix.inputName
        info.isSplitStereo = true
        info.includesSystemAudio = true
        let note = RecordingJournal.makeNote(info, fileName: "a.m4a", duration: 5)
        XCTAssertEqual(note.speakers.map(\.name), [AppSettings.myName ?? "Me", SystemAudioMix.othersName])
    }

    @MainActor
    func testASplitStereoMicrophoneKeepsItsInputAndSpeakers() {
        var info = RecordingJournal.Info(title: nil, startedAt: Date(), continues: nil)
        info.channels = 2
        info.inputName = "DJI Mic"
        info.isSplitStereo = true
        info.includesSystemAudio = false
        info.speakerNames = ["Speaker 1", " "]
        let note = RecordingJournal.makeNote(info, fileName: "a.m4a", duration: 5)
        XCTAssertEqual(note.inputName, "DJI Mic")
        XCTAssertEqual(note.speakerMode, .channels)
        XCTAssertEqual(note.speakers.map(\.name), ["Speaker 1", "Speaker 2"])
    }

    @MainActor
    func testAMonoCopyIsRecoveredAsBefore() {
        let info = RecordingJournal.Info(title: nil, startedAt: Date(), continues: nil, notes: [.init(at: 2, text: "Note")])
        let note = RecordingJournal.makeNote(info, fileName: "a.m4a", duration: 5)
        XCTAssertEqual(note.channelCount, 1)
        XCTAssertEqual(note.inputName, "Recovered")
        XCTAssertEqual(note.speakerMode, .none)
        XCTAssertTrue(note.speakers.isEmpty)
        XCTAssertTrue(note.text.contains("Note"))
    }

    // MARK: The sound

    /// Interleaved 16-bit frames: a tone on the left, silence on the right, and half a frame cut off at the end.
    private func plainStereo(seconds: Double) throws -> URL {
        let frames = Int(seconds * RecordingJournal.sampleRate)
        var samples: [Int16] = []
        samples.reserveCapacity(frames * 2)
        for index in 0..<frames {
            samples.append(Int16(12_000 * sin(Double(index) * 2 * .pi * 440 / RecordingJournal.sampleRate)))
            samples.append(0)
        }
        var data = samples.withUnsafeBytes { Data($0) }
        data.append(contentsOf: [1, 2])
        let url = folder.appendingPathComponent("sound.pcm")
        try data.write(to: url)
        return url
    }

    func testAStereoCopyBecomesAStereoFileWithItsChannelsApart() throws {
        let sound = try plainStereo(seconds: 2)
        let output = folder.appendingPathComponent("out.m4a")
        let duration = try XCTUnwrap(RecordingJournal.encode(sound, channels: 2, to: output))
        XCTAssertEqual(duration, 2, accuracy: 0.01)

        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 2, accuracy: 0.1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let data = try XCTUnwrap(buffer.floatChannelData)
        let frames = Int(buffer.frameLength)
        func energy(_ channel: Int) -> Float { (0..<frames).reduce(0) { $0 + data[channel][$1] * data[channel][$1] } }
        XCTAssertGreaterThan(energy(0), 100 * max(energy(1), 1e-6), "the left channel's sound stays on the left")
    }

    func testLessThanASecondIsNoRecording() throws {
        let sound = try plainStereo(seconds: 0.6)
        let output = folder.appendingPathComponent("short.m4a")
        XCTAssertNil(try RecordingJournal.encode(sound, channels: 2, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
