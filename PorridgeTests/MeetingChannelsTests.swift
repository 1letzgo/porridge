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
            Word(text: "banana", start: 2.6, end: 2.9),       // nobody said it there, but the microphone has only the echo
        ]
        let kept = SpeakerAssigner.droppingEcho(left: left, right: right, energy: energy)
        XCTAssertEqual(kept.map(\.text), ["Hello"])
    }

    func testTheUsersOwnWordIsKeptEvenWhenTheOthersSayIt() {
        // The user says "launch" at 0.5 s, louder on the microphone; the others say it too.
        let right = [Word(text: "launch", start: 0.6, end: 0.9)]
        let left = [Word(text: "launch", start: 0.5, end: 0.9)]
        XCTAssertEqual(SpeakerAssigner.droppingEcho(left: left, right: right, energy: energy).count, 1)
        // Too far apart in time to be the echo (the user's voice on the microphone, quieter than the others).
        let late = [Word(text: "Launch", start: 2.0, end: 2.4)]
        let echoLater = [Word(text: "launch", start: 2.9, end: 3.0)]
        var spoken = energy.left
        for i in 58...60 { spoken[i] = 0.2 }
        let withVoice = ChannelEnergy(frameDuration: 0.05, left: spoken, right: energy.right)
        XCTAssertEqual(SpeakerAssigner.droppingEcho(left: echoLater, right: late, energy: withVoice).count, 1)
        // Without words on the right nothing is dropped.
        XCTAssertEqual(SpeakerAssigner.droppingEcho(left: left, right: [], energy: energy).count, 1)
    }

    /// Thirty seconds: the user speaks loudly at 0–4 s; the others at 24.5–26.95 s and 27.2–28.7 s, picked up by
    /// the microphone 80 ms later and 15 dB quieter (as `scripts/make-meeting-fixture.sh` builds the echo).
    private var callEnergy: ChannelEnergy {
        var left = [Float](repeating: 0, count: 600)
        var right = [Float](repeating: 0, count: 600)
        for i in 0..<80 { left[i] = 1 }
        for i in Array(490..<539) + Array(544..<574) {
            right[i] = 1
            left[min(599, i + 2)] = 0.03
        }
        return ChannelEnergy(frameDuration: 0.05, left: left, right: right)
    }

    private let othersSentence = [
        Word(text: "once", start: 25.5, end: 25.8), Word(text: "the", start: 25.8, end: 25.95),
        Word(text: "numbers", start: 26.0, end: 26.35), Word(text: "are", start: 26.35, end: 26.45),
        Word(text: "in.", start: 26.45, end: 26.95),
        Word(text: "The", start: 27.2, end: 27.4), Word(text: "layout", start: 27.4, end: 27.8),
    ]

    func testALoneEchoWordInsideTheOthersSentenceIsDropped() {
        // The echo's last word, recognized late on the microphone where the others' sound has nearly ended.
        let left = [Word(text: "Good", start: 0.1, end: 0.5), Word(text: "morning.", start: 0.5, end: 1.0), Word(text: "in.", start: 27.0, end: 27.2)]
        let kept = SpeakerAssigner.droppingEcho(left: left, right: othersSentence, energy: callEnergy)
        XCTAssertEqual(kept.map(\.text), ["Good", "morning."])
    }

    func testTheUsersShortReplyIsKept() {
        // "Okay." while the others speak, quieter on the microphone than their sound (7 dB) but above their echo
        // (8 dB), not said by them: kept.
        var okay = callEnergy.left
        for i in 522...528 { okay[i] = 0.2 }
        let left = [Word(text: "Okay.", start: 26.1, end: 26.4)]
        let replied = ChannelEnergy(frameDuration: 0.05, left: okay, right: callEnergy.right)
        XCTAssertEqual(SpeakerAssigner.droppingEcho(left: left, right: othersSentence, energy: replied).map(\.text), ["Okay."])
        // "Yes." of the user after the others, loud on the microphone: kept, even when the others said "yes" before.
        var energy = callEnergy
        var louder = energy.left
        for i in 580..<590 { louder[i] = 1 }
        energy = ChannelEnergy(frameDuration: 0.05, left: louder, right: energy.right)
        let yes = [Word(text: "Yes.", start: 29.0, end: 29.4)]
        let said = othersSentence + [Word(text: "yes", start: 28.4, end: 28.7)]
        XCTAssertEqual(SpeakerAssigner.droppingEcho(left: yes, right: said, energy: energy).map(\.text), ["Yes."])
    }

    // MARK: The user said nothing (microphone muted in the call)

    /// The others take turns at 1–9 s and 11–19 s on the Mac's sound; the microphone hears them from the
    /// loudspeaker 15 dB quieter, 80 ms later and reverberant, over the room's noise (`SyntheticCall`). The user is
    /// muted in the call and says nothing.
    nonisolated static func mutedCallSound() -> (microphone: [Float], system: [Float]) {
        let others = SyntheticCall.speech(seconds: 20, spans: [(1, 9), (11, 19)], seed: 7, level: 0.3)
        let microphone = SyntheticCall.mix([
            SyntheticCall.echo(of: others, attenuationDB: 15, delay: 0.08),
            SyntheticCall.noise(count: others.count, level: 0.0006, seed: 3),
        ])
        return (microphone, others)
    }

    private func mutedCall() throws -> ChannelEnergy {
        let call = Self.mutedCallSound()
        return try SyntheticCall.energy(microphone: call.microphone, system: call.system)
    }

    func testTheOthersEchoIsNoWordOfTheUserEvenWhenTheirWordsDiffer() throws {
        let energy = try mutedCall()
        // The others' recognizer heard different words, or none, where the microphone's made something of the echo.
        let right = [Word(text: "Launch", start: 2.0, end: 2.4), Word(text: "tomorrow", start: 2.4, end: 2.9),
                     Word(text: "numbers", start: 12.0, end: 12.4)]
        let left = [
            Word(text: "lunch", start: 2.1, end: 2.4), Word(text: "to", start: 2.45, end: 2.6), Word(text: "borrow", start: 2.6, end: 2.95),
            Word(text: "We", start: 4.0, end: 4.2), Word(text: "should", start: 4.2, end: 4.5), Word(text: "ship", start: 4.5, end: 4.8),
            Word(text: "Okay.", start: 12.5, end: 12.8),
            Word(text: "Mm.", start: 19.1, end: 19.3),           // the room's echo after the others stopped
        ]
        XCTAssertEqual(SpeakerAssigner.droppingEcho(left: left, right: right, energy: energy).map(\.text), [])
        // Nothing recognized on the Mac's side at all.
        XCTAssertEqual(SpeakerAssigner.droppingEcho(left: left, right: [], energy: energy).map(\.text), [])
    }

    func testWordsMadeUpOnTheMicrophonesNoiseAreDropped() throws {
        // Headphones: no echo, the microphone only hears the room; the Mac's sound now and then.
        let others = SyntheticCall.speech(seconds: 12, spans: [(6, 10)], seed: 11, level: 0.3)
        let microphone = SyntheticCall.noise(count: others.count, level: 0.0006, seed: 5)
        let energy = try SyntheticCall.energy(microphone: microphone, system: others)
        let left = [Word(text: "Thank", start: 1.0, end: 1.3), Word(text: "you.", start: 1.3, end: 1.6),
                    Word(text: "Bye.", start: 7.0, end: 7.3)]
        XCTAssertEqual(SpeakerAssigner.droppingEcho(left: left, right: [], energy: energy).map(\.text), [])
        XCTAssertEqual(SpeakerAssigner.droppingEcho(left: left, right: [Word(text: "So", start: 6.5, end: 6.7)], energy: energy).map(\.text), [])
    }

    /// The others speak throughout 1–19 s; the user speaks alone at 20–23 s, talks over them at 6–8 s (6 dB
    /// quieter than their sound) and says a short "Yes." at 12.2–12.5 s (9 dB quieter, 6 dB above their echo); the
    /// microphone also hears the others' echo as in `mutedCall`.
    nonisolated static func callWithTheUser() -> (microphone: [Float], system: [Float]) {
        let others = SyntheticCall.speech(seconds: 24, spans: [(1, 19)], seed: 7, level: 0.3)
        let user = SyntheticCall.mix([
            SyntheticCall.speech(seconds: 24, spans: [(20, 23)], seed: 21, level: 0.3),
            SyntheticCall.speech(seconds: 24, spans: [(6, 8)], seed: 22, level: 0.15),
            SyntheticCall.speech(seconds: 24, spans: [(12.2, 12.5)], seed: 23, level: 0.106),
        ])
        let microphone = SyntheticCall.mix([
            user,
            SyntheticCall.echo(of: others, attenuationDB: 15, delay: 0.08),
            SyntheticCall.noise(count: others.count, level: 0.0006, seed: 3),
        ])
        return (microphone, others)
    }

    func testTheUsersOwnWordsOverTheOthersAndTheirEchoAreKept() throws {
        let call = Self.callWithTheUser()
        let energy = try SyntheticCall.energy(microphone: call.microphone, system: call.system)
        let right = [Word(text: "the", start: 6.2, end: 6.4), Word(text: "plan", start: 6.4, end: 6.8),
                     Word(text: "Yes,", start: 12.1, end: 12.4)]
        let left = [
            Word(text: "No,", start: 6.1, end: 6.4), Word(text: "the", start: 6.4, end: 6.6), Word(text: "plan", start: 6.6, end: 7.0),
            Word(text: "changed.", start: 7.0, end: 7.8),
            Word(text: "Yes.", start: 12.2, end: 12.5),
            Word(text: "banana", start: 15.0, end: 15.3),        // the echo alone
            Word(text: "Thanks", start: 20.2, end: 20.6), Word(text: "everyone.", start: 20.6, end: 21.2),
        ]
        XCTAssertEqual(SpeakerAssigner.droppingEcho(left: left, right: right, energy: energy).map(\.text),
                       ["No,", "the", "plan", "changed.", "Yes.", "Thanks", "everyone."])
    }

    func testTheEchoIsMeasuredWithTheRoomsCoupling() throws {
        let voice = MicrophoneVoice(try mutedCall())
        // Nothing of the user's own anywhere in the muted call.
        XCTAssertEqual(try XCTUnwrap(voice.ownSeconds(from: 0, to: 20)), 0, accuracy: 0.051)
        // Not measured: kept in doubt.
        XCTAssertNil(voice.ownSeconds(from: 30, to: 31))
        XCTAssertTrue(voice.mayBeUser(from: 30, to: 31))
    }

    func testEchoIslands() {
        let words = [
            Word(text: "a", start: 0, end: 0.2), Word(text: "b", start: 0.3, end: 0.5),
            Word(text: "c", start: 2, end: 2.2),
            Word(text: "d", start: 4, end: 4.2), Word(text: "e", start: 4.3, end: 4.5), Word(text: "f", start: 4.6, end: 4.8),
            Word(text: "g", start: 6, end: 7.5),
        ]
        XCTAssertEqual(SpeakerAssigner.echoIslands(words), [[0, 1], [2]])
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

/// Speech-like test sound for a call: noise in syllables of about 4 per second with varying loudness, the
/// loudspeaker's echo of it on the microphone (delayed, quieter, with a short reverberation tail), room noise.
/// Deterministic, 16 kHz, nothing is played.
enum SyntheticCall {
    static let rate = 16_000

    /// Noise of `level` (peak) from a seeded generator.
    static func noise(count: Int, level: Float, seed: UInt64) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return level * (Float(state >> 40) / Float(1 << 24) * 2 - 1)
        }
    }

    /// Syllables of noise within the given spans (seconds) of `seconds`, at most `level` loud.
    static func speech(seconds: Double, spans: [(Double, Double)], seed: UInt64, level: Float) -> [Float] {
        let carrier = noise(count: Int(seconds * Double(rate)), level: 1, seed: seed)
        let loudness = noise(count: 400, level: 1, seed: seed + 99).map { 0.6 + 0.4 * abs($0) }
        return carrier.enumerated().map { index, value in
            let t = Double(index) / Double(rate)
            guard spans.contains(where: { t >= $0.0 && t < $0.1 }) else { return 0 }
            let position = t * 4.3
            let syllable = Int(position)
            let envelope = Float(max(0, sin((position - Double(syllable)) * .pi)))
            return value * level * envelope * loudness[syllable % loudness.count]
        }
    }

    /// `sound` from a loudspeaker on the microphone: `delay` seconds later, `attenuationDB` quieter, with a few
    /// reflections falling off over some 160 ms.
    static func echo(of sound: [Float], attenuationDB: Float, delay: Double) -> [Float] {
        let taps: [(Double, Float)] = [(0, 1), (0.013, 0.6), (0.029, 0.45), (0.047, 0.35), (0.071, 0.25), (0.11, 0.15), (0.16, 0.08)]
        let norm = taps.map { $0.1 * $0.1 }.reduce(0, +).squareRoot()
        let gain = pow(10, -attenuationDB / 20) / norm
        var out = [Float](repeating: 0, count: sound.count)
        for (offset, weight) in taps {
            let shift = Int((delay + offset) * Double(rate))
            guard shift < sound.count else { continue }
            for i in shift..<sound.count { out[i] += sound[i - shift] * weight * gain }
        }
        return out
    }

    static func mix(_ parts: [[Float]]) -> [Float] {
        let count = parts.map(\.count).max() ?? 0
        var out = [Float](repeating: 0, count: count)
        for part in parts { for (i, v) in part.enumerated() { out[i] += v } }
        return out
    }

    /// The channel levels as the processing measures them: a stereo file (microphone left, Mac's sound right)
    /// through `AudioPreprocessor`.
    static func energy(microphone: [Float], system: [Float]) throws -> ChannelEnergy {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let count = min(microphone.count, system.count)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let data = try XCTUnwrap(buffer.floatChannelData)
            for i in 0..<count {
                data[0][i] = microphone[i]
                data[1][i] = system[i]
            }
            try file.write(from: buffer)
        }
        let prepared = try AudioPreprocessor.prepare(source: url, measureChannels: true)
        defer { prepared.removeFiles() }
        return try XCTUnwrap(prepared.channelEnergy)
    }
}
