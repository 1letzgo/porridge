import AVFoundation
import XCTest
@testable import Porridge

/// Meetings recorded on the Mac with its sound: each channel recognized on its own, the microphone's echo of the
/// others dropped, and speakers that are one person made one.
@MainActor
final class MeetingChannelsTests: XCTestCase {
    // MARK: The left channel alone

    func testLeftChannelIsWrittenAlone() throws {
        let rate = 48_000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate)))
            buffer.frameLength = AVAudioFrameCount(rate)
            let data = try XCTUnwrap(buffer.floatChannelData)
            for i in 0..<Int(rate) {
                data[0][i] = 0.5 * sin(Float(i) * 2 * .pi * 440 / Float(rate)) // left: a tone (the user)
                data[1][i] = 0                                                 // right: silence (the others)
            }
            try file.write(from: buffer)
        }
        let prepared = try AudioPreprocessor.prepare(source: url, measureChannels: true, keepRightChannel: true, keepLeftChannel: true)
        defer { prepared.removeFiles() }
        let leftURL = try XCTUnwrap(prepared.leftURL)
        XCTAssertNotNil(prepared.rightURL)
        XCTAssertNotEqual(leftURL, prepared.rightURL)
        let left = try AVAudioFile(forReading: leftURL)
        let mix = try AVAudioFile(forReading: prepared.monoURL)
        XCTAssertEqual(left.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(left.length, mix.length, accuracy: 64)
        func peak(_ file: AVAudioFile) throws -> Float {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            return (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0
        }
        // The left channel alone is louder than the mix it is half of; the right one is silent.
        XCTAssertGreaterThan(try peak(left), try peak(mix) * 1.5)
        XCTAssertLessThan(try peak(AVAudioFile(forReading: XCTUnwrap(prepared.rightURL))), 0.01)

        let plain = try AudioPreprocessor.prepare(source: url, measureChannels: true, keepRightChannel: true)
        defer { plain.removeFiles() }
        XCTAssertNil(plain.leftURL)
    }

    // MARK: Two streams of words become one

    func testChannelsAreMergedByPhraseInTimeOrder() {
        let left = [Word(text: "Hi", start: 0, end: 0.3), Word(text: "there.", start: 0.3, end: 0.6), Word(text: "Yes", start: 5, end: 5.3)]
        let right = [Word(text: "Hello", start: 0.2, end: 0.5), Word(text: "all", start: 0.5, end: 0.8), Word(text: "fine", start: 2, end: 2.3)]
        let merged = SpeakerAssigner.mergeChannels(left: left, right: right)
        XCTAssertEqual(merged.words.map(\.text), ["Hi", "there.", "Hello", "all", "fine", "Yes"])
        XCTAssertEqual(merged.ids, ["ch0", "ch0", "ch1", "ch1", "ch1", "ch0"])

        XCTAssertEqual(SpeakerAssigner.mergeChannels(left: [], right: right).ids, ["ch1", "ch1", "ch1"])
        XCTAssertTrue(SpeakerAssigner.mergeChannels(left: [], right: []).words.isEmpty)
    }

    // MARK: The microphone's echo of the others

    /// Five seconds: the user speaks loudly at 0–1 s; at 2–3 s the others speak and the microphone picks them up
    /// 15 dB quieter.
    private var energy: ChannelEnergy {
        var left = [Float](repeating: 0, count: 100)
        var right = [Float](repeating: 0, count: 100)
        for i in 0..<20 { left[i] = 1 }
        for i in 40..<60 {
            right[i] = 1
            left[i] = 0.03
        }
        return ChannelEnergy(frameDuration: 0.05, left: left, right: right)
    }

    func testEchoOfTheOthersIsDropped() {
        let right = [Word(text: "Launch", start: 2.0, end: 2.4), Word(text: "tomorrow", start: 2.4, end: 2.9)]
        let left = [
            Word(text: "Hello", start: 0.1, end: 0.5),        // the user
            Word(text: "launch,", start: 2.08, end: 2.45),    // echo, same word
            Word(text: "tomorow", start: 2.5, end: 2.95),     // echo, recognized a letter off
            Word(text: "banana", start: 2.6, end: 2.9),       // loud on the right, but nobody said it there: kept
        ]
        let kept = SpeakerAssigner.droppingEcho(left: left, right: right, energy: energy)
        XCTAssertEqual(kept.map(\.text), ["Hello", "banana"])
    }

    func testTheUsersOwnWordIsKeptEvenWhenTheOthersSayIt() {
        // The user says "launch" at 0.5 s, louder on the microphone; the others say it too.
        let right = [Word(text: "launch", start: 0.6, end: 0.9)]
        let left = [Word(text: "launch", start: 0.5, end: 0.9)]
        XCTAssertEqual(SpeakerAssigner.droppingEcho(left: left, right: right, energy: energy).count, 1)
        // Too far apart in time to be the echo.
        let late = [Word(text: "Launch", start: 2.0, end: 2.4)]
        let echoLater = [Word(text: "launch", start: 2.9, end: 3.0)]
        XCTAssertEqual(SpeakerAssigner.droppingEcho(left: echoLater, right: late, energy: energy).count, 1)
        // Without words on the right nothing is dropped.
        XCTAssertEqual(SpeakerAssigner.droppingEcho(left: left, right: [], energy: energy).count, 1)
    }

    func testSameWord() {
        XCTAssertTrue(SpeakerAssigner.sameWord("Launch,", "launch"))
        XCTAssertTrue(SpeakerAssigner.sameWord("tomorrow", "tomorow"))
        XCTAssertFalse(SpeakerAssigner.sameWord("cat", "car"))
        XCTAssertFalse(SpeakerAssigner.sameWord("launch", "lunch break"))
        XCTAssertFalse(SpeakerAssigner.sameWord("...", "..."))
    }

    // MARK: The most voices

    func testMaxSpeakersFromInvitedPeople() {
        XCTAssertNil(SpeakerAssigner.maxSpeakers(invited: 0, othersOnly: true))
        XCTAssertNil(SpeakerAssigner.maxSpeakers(invited: 0, othersOnly: false))
        // Three invited besides the user: on the others' channel three voices, with everybody five.
        XCTAssertEqual(SpeakerAssigner.maxSpeakers(invited: 3, othersOnly: true), 3)
        XCTAssertEqual(SpeakerAssigner.maxSpeakers(invited: 3, othersOnly: false), 5)
    }

    // MARK: Voices on the others' channel

    private func words(_ count: Int, length: Double = 1) -> [Word] {
        (0..<count).map { Word(text: "w\($0)", start: Double($0) * length, end: Double($0 + 1) * length) }
    }

    func testShortVoiceGoesToTheVoiceItSoundsLike() {
        let words = words(40)
        let ids: [String?] = Array(repeating: "ch1", count: 40)
        // B 0–15 and 20–25, a short X 15–20 that sounds like C, C 25–40.
        let segments = [
            DiarizedSegment(speaker: "B", start: 0, end: 15),
            DiarizedSegment(speaker: "X", start: 15, end: 20),
            DiarizedSegment(speaker: "B", start: 20, end: 25),
            DiarizedSegment(speaker: "C", start: 25, end: 40),
        ]
        let voices: [String: [Float]] = ["B": [1, 0, 0], "C": [0, 1, 0], "X": [0.1, 0.9, 0.1]]
        let withVoices = SpeakerAssigner.splitChannel(words, ids: ids, channel: "ch1", segments: segments, voices: voices)
        XCTAssertEqual(withVoices.added, ["ch1.2"])
        XCTAssertEqual(withVoices.ids[17], "ch1.2")
        XCTAssertEqual(withVoices.ids[30], "ch1.2")
        XCTAssertEqual(withVoices.ids[5], "ch1")

        // Without voice prints the short voice stays with the voice before it.
        let without = SpeakerAssigner.splitChannel(words, ids: ids, channel: "ch1", segments: segments)
        XCTAssertEqual(without.ids[17], "ch1")
    }

    func testAPhraseGoesToTheVoiceWithMostOfIt() {
        let words = (0..<6).map { Word(text: "w\($0)", start: Double($0) * 0.4, end: Double($0) * 0.4 + 0.35) }
        let all = Set(words.indices)
        XCTAssertEqual(SpeakerAssigner.majorityByPhrase(["a", "a", "b", "a", "a", "a"], words: words, among: all), Array(repeating: "a", count: 6))
        // A tie changes nothing.
        XCTAssertEqual(SpeakerAssigner.majorityByPhrase(["a", "a", "a", "b", "b", "b"], words: words, among: all), ["a", "a", "a", "b", "b", "b"])

        // A pause and a sentence end make phrases of their own.
        var paused = words
        paused[3] = Word(text: "w3", start: 3, end: 3.3)
        paused[4] = Word(text: "w4", start: 3.3, end: 3.6)
        paused[5] = Word(text: "w5", start: 3.6, end: 3.9)
        XCTAssertEqual(SpeakerAssigner.phrases(paused, among: all), [[0, 1, 2], [3, 4, 5]])
        var sentence = words
        sentence[1].text = "done."
        XCTAssertEqual(SpeakerAssigner.phrases(sentence, among: all), [[0, 1], [2, 3, 4, 5]])
        // Words of another channel in between split a phrase too.
        XCTAssertEqual(SpeakerAssigner.phrases(words, among: [0, 1, 3, 4]), [[0, 1], [3, 4]])
    }

    // MARK: One person, one speaker

    private func voice(_ hot: Int, size: Int = 8) -> Data {
        var v = [Float](repeating: 0.05, count: size)
        v[hot] = 1
        return VoiceMath.data(from: VoiceMath.normalized(v))
    }

    private func speaker(_ id: String, _ name: String, voice: Data? = nil, profile: String? = nil) -> Speaker {
        Speaker(id: id, name: name, colorIndex: 0, voice: voice, voiceSeconds: voice == nil ? nil : 20, profileID: profile)
    }

    private let segments = [
        TranscriptSegment(speakerId: "ch0", start: 0, end: 4, text: "Hello."),
        TranscriptSegment(speakerId: "ch1", start: 5, end: 9, text: "Hi."),
        TranscriptSegment(speakerId: "ch1.2", start: 9.5, end: 12, text: "Same person."),
        TranscriptSegment(speakerId: "ch1.3", start: 13, end: 16, text: "Someone else."),
    ]

    func testUnnamedSpeakersWithTheSameVoiceBecomeOne() {
        let speakers = [
            speaker("ch0", "Me", voice: voice(0)),
            speaker("ch1", "Speaker 2", voice: voice(1)),
            speaker("ch1.2", "Speaker 3", voice: voice(1)),
            speaker("ch1.3", "Speaker 4", voice: voice(2)),
        ]
        let merged = SpeakerMerge.mergingSameVoices(speakers, segments: segments)
        XCTAssertEqual(merged.speakers.map(\.id), ["ch0", "ch1", "ch1.3"])
        XCTAssertEqual(merged.speakers[1].voiceSeconds, 40)
        // The two turns of the same voice, half a second apart, are one segment now.
        XCTAssertEqual(merged.segments.map(\.speakerId), ["ch0", "ch1", "ch1.3"])
        XCTAssertEqual(merged.segments[1].text, "Hi. Same person.")
        XCTAssertEqual(merged.segments[1].end, 12)
    }

    func testNamedOrOtherChannelSpeakersAreNotMergedByVoice() {
        // Same voice, but one has a name, or they are on different microphones.
        let named = [speaker("ch1", "Anna", voice: voice(1)), speaker("ch1.2", "Speaker 3", voice: voice(1))]
        XCTAssertEqual(SpeakerMerge.mergingSameVoices(named, segments: segments).speakers.count, 2)
        let channels = [speaker("ch0", "Speaker 1", voice: voice(1)), speaker("ch1", "Speaker 2", voice: voice(1))]
        XCTAssertEqual(SpeakerMerge.mergingSameVoices(channels, segments: segments).speakers.count, 2)
        // Voices not alike enough.
        let different = [speaker("s1", "Speaker 1", voice: voice(1)), speaker("s2", "Speaker 2", voice: voice(2))]
        XCTAssertEqual(SpeakerMerge.mergingSameVoices(different, segments: segments).speakers.count, 2)
        // Without voice prints nothing is merged.
        let silent = [speaker("s1", "Speaker 1"), speaker("s2", "Speaker 2")]
        XCTAssertEqual(SpeakerMerge.mergingSameVoices(silent, segments: segments).speakers.count, 2)
        XCTAssertEqual(SpeakerMerge.source(of: "ch1.3"), "ch1")
        XCTAssertEqual(SpeakerMerge.source(of: "s4"), "s")
    }

    func testRenamingToAnotherSpeakersNameMergesThem() {
        let profile = UUID().uuidString
        // "Speaker 3" was just named "me": the meeting's "Me" is the same person.
        let speakers = [
            speaker("ch0", "Me", voice: voice(0)),
            speaker("ch1", "Speaker 2", voice: voice(1)),
            speaker("ch1.2", "me", voice: voice(0), profile: profile),
        ]
        let merged = SpeakerNaming.mergingSameName("ch1.2", speakers: speakers, segments: segments)
        XCTAssertEqual(merged.speakers.map(\.id), ["ch0", "ch1"])
        XCTAssertEqual(merged.speakers[0].name, "Me")
        XCTAssertEqual(merged.speakers[0].profileID, profile)
        XCTAssertEqual(merged.segments.first { $0.text == "Same person." }?.speakerId, "ch0")
        XCTAssertFalse(merged.segments.contains { $0.speakerId == "ch1.2" })

        // A name nobody else has changes nothing.
        let unique = [speaker("ch0", "Me"), speaker("ch1", "Anna")]
        let same = SpeakerNaming.mergingSameName("ch1", speakers: unique, segments: segments)
        XCTAssertEqual(same.speakers, unique)
        XCTAssertEqual(same.segments, segments)
    }
}
