import XCTest
@testable import Porridge

/// Speakers while recording: chat bubbles, the echo of the Mac's sound in the microphone, telling voices apart
/// live, naming them after known voices, and the pauses that end a live piece.
final class LiveSpeakerTests: XCTestCase {
    // MARK: Bubbles

    private func item(_ speaker: String?, _ text: String, at start: Double, final: Bool = true) -> TranscriptBubbles.Item {
        TranscriptBubbles.Item(id: UUID(), speakerID: speaker, text: text, isFinal: final, start: start, end: start + 2)
    }

    private let speakers: [String: BubbleSpeaker] = [
        "ch0": BubbleSpeaker(id: "ch0", name: "Me", colorIndex: 0, isMe: true),
        "ch1": BubbleSpeaker(id: "ch1", name: "Others", colorIndex: 1, isMe: false),
        "ch1.2": BubbleSpeaker(id: "ch1.2", name: "Speaker 3", colorIndex: 2, isMe: false),
    ]

    func testConsecutiveUtterancesOfOneSpeakerAreOneBubble() {
        let items = [item("ch1", "Hello.", at: 0), item("ch1", "How are you?", at: 2.5), item("ch0", "Fine.", at: 5)]
        let bubbles = TranscriptBubbles.bubbles(items, speakers: speakers)
        XCTAssertEqual(bubbles.count, 2)
        XCTAssertEqual(bubbles[0].text, "Hello. How are you?")
        XCTAssertEqual(bubbles[0].id, items[0].id, "a growing bubble keeps its id")
        XCTAssertEqual(bubbles[1].text, "Fine.")
    }

    func testMeIsOnTheRightEverybodyElseOnTheLeft() {
        let bubbles = TranscriptBubbles.bubbles(
            [item("ch1", "Hi", at: 0), item("ch0", "Hi", at: 3), item("ch1.2", "Hello", at: 6)], speakers: speakers)
        XCTAssertEqual(bubbles.map(\.side), [.leading, .trailing, .leading])
        XCTAssertEqual(bubbles.map { $0.speaker?.colorIndex }, [1, 0, 2])
    }

    func testNameOnlyWhereTheSpeakerChanges() {
        // A long silence starts a new bubble of the same speaker, without the name again.
        let items = [item("ch1", "One", at: 0), item("ch1", "Two", at: 60), item("ch0", "Three", at: 63)]
        let bubbles = TranscriptBubbles.bubbles(items, speakers: speakers)
        XCTAssertEqual(bubbles.count, 3)
        XCTAssertEqual(bubbles.map(\.showsName), [true, false, true])
    }

    func testOpenTextIsKeptApartAndBubbleIsNotFinal() {
        let bubbles = TranscriptBubbles.bubbles([item("ch1", "Done.", at: 0), item("ch1", "still talk", at: 2.2, final: false)], speakers: speakers)
        XCTAssertEqual(bubbles.count, 1)
        XCTAssertEqual(bubbles[0].parts.map(\.isFinal), [true, false])
        XCTAssertFalse(bubbles[0].isFinal)
    }

    func testWithoutSpeakersEverythingIsLeftWithoutNames() {
        let bubbles = TranscriptBubbles.bubbles([item(nil, "Just text", at: 0), item(nil, "and more", at: 2)], speakers: [:])
        XCTAssertEqual(bubbles.count, 1)
        XCTAssertEqual(bubbles[0].side, .leading)
        XCTAssertFalse(bubbles[0].showsName)
    }

    func testEmptyTextMakesNoBubble() {
        XCTAssertTrue(TranscriptBubbles.bubbles([item("ch0", "", at: 0)], speakers: speakers).isEmpty)
    }

    func testRowsOfAFinishedTranscript() {
        let rows = TranscriptBubbles.rows(speakerIDs: ["ch1", "ch1", "ch0", nil, "ch0"], meIDs: ["ch0"])
        XCTAssertEqual(rows.map(\.side), [.leading, .leading, .trailing, .leading, .trailing])
        XCTAssertEqual(rows.map(\.showsName), [true, false, true, false, true])
    }

    func testRowsWithoutMeAreAllLeft() {
        let rows = TranscriptBubbles.rows(speakerIDs: ["s1", "s2", "s1"], meIDs: [])
        XCTAssertEqual(rows.map(\.side), [.leading, .leading, .leading])
    }

    func testLiveSpeakerNames() {
        func speaker(_ id: String, all: Set<String>, known: [String: String] = [:]) -> BubbleSpeaker {
            TranscriptBubbles.liveSpeaker(id: id, allIDs: all, knownNames: known, meName: "Dana", othersName: "Others", isMeName: { $0 == "Dana" })
        }
        XCTAssertEqual(speaker("ch0", all: ["ch0", "ch1"]), BubbleSpeaker(id: "ch0", name: "Dana", colorIndex: 0, isMe: true))
        XCTAssertEqual(speaker("ch1", all: ["ch0", "ch1"]).name, "Others")
        // Once a second voice is heard on the Mac's sound, the first is "Speaker 2", as after recording.
        XCTAssertEqual(speaker("ch1", all: ["ch1", "ch1.2"]).name, "Speaker 2")
        XCTAssertEqual(speaker("ch1.2", all: ["ch1", "ch1.2"]), BubbleSpeaker(id: "ch1.2", name: "Speaker 3", colorIndex: 2, isMe: false))
        XCTAssertEqual(speaker("ch1.3", all: ["ch1", "ch1.3"], known: ["ch1.3": "Anna"]).name, "Anna")
        XCTAssertEqual(speaker("s2", all: ["s1", "s2"]), BubbleSpeaker(id: "s2", name: "Speaker 2", colorIndex: 1, isMe: false))
        // A known voice that is the user is on the user's side.
        XCTAssertTrue(speaker("s1", all: ["s1"], known: ["s1": "Dana"]).isMe)
    }

    // MARK: Echo

    func testEchoOfTheMacsSoundIsRecognized() {
        XCTAssertTrue(LiveEcho.isEcho(
            microphone: "we should ship it on Monday", microphoneLevel: -48, systemLevel: -22,
            system: ["I think we should ship it on Monday."]))
    }

    func testOwnSpeechIsNotAnEcho() {
        // Different words.
        XCTAssertFalse(LiveEcho.isEcho(
            microphone: "No, Tuesday is better", microphoneLevel: -48, systemLevel: -22, system: ["We should ship it on Monday."]))
        // The same words, but the microphone was as loud: the user said it (repeating the others).
        XCTAssertFalse(LiveEcho.isEcho(
            microphone: "ship it on Monday", microphoneLevel: -24, systemLevel: -22, system: ["ship it on Monday"]))
    }

    func testInDoubtTheMicrophoneIsKept() {
        // Too short to tell.
        XCTAssertFalse(LiveEcho.isEcho(microphone: "Yes", microphoneLevel: -50, systemLevel: -20, system: ["Yes"]))
        // Nothing measured.
        XCTAssertFalse(LiveEcho.isEcho(microphone: "ship it on Monday", microphoneLevel: nil, systemLevel: -20, system: ["ship it on Monday"]))
        // Nothing said on the Mac at that time.
        XCTAssertFalse(LiveEcho.isEcho(microphone: "ship it on Monday", microphoneLevel: -50, systemLevel: -20, system: []))
    }

    func testSimilarityIgnoresCaseAndPunctuation() {
        XCTAssertEqual(LiveEcho.similarity(microphone: "Ship it, Monday!", system: "ship IT on monday"), 1)
        XCTAssertEqual(LiveEcho.similarity(microphone: "ship it now", system: "ship it"), 2.0 / 3, accuracy: 0.001)
        XCTAssertEqual(LiveEcho.similarity(microphone: "", system: "anything"), 0)
    }

    // MARK: Voices

    /// A unit vector along `axis` with a little of `other` mixed in.
    private func voice(_ axis: Int, _ other: Int = 0, mix: Float = 0) -> [Float] {
        var v = [Float](repeating: 0, count: 8)
        v[axis] = 1
        v[other] += mix
        return v
    }

    func testSameVoiceKeepsItsIdNewVoiceGetsTheNext() {
        var clusters = LiveVoiceClusters(scheme: .channel("ch1"))
        XCTAssertEqual(clusters.assign(voice(0), seconds: 3), "ch1")
        XCTAssertEqual(clusters.assign(voice(0, 1, mix: 0.3), seconds: 3), "ch1", "similar (cos 0.96) is the same voice")
        XCTAssertEqual(clusters.assign(voice(1), seconds: 3), "ch1.2")
        XCTAssertEqual(clusters.assign(voice(2), seconds: 3), "ch1.3")
        XCTAssertEqual(clusters.assign(voice(1, 2, mix: 0.2), seconds: 2), "ch1.2")
        XCTAssertEqual(clusters.voices.map(\.seconds), [6, 5, 3])
    }

    func testThresholdOfTheSameVoice() {
        var clusters = LiveVoiceClusters(scheme: .voices)
        XCTAssertEqual(clusters.assign(voice(0), seconds: 2), "s1")
        // cos = 1 / sqrt(2) ≈ 0.707: just the same voice.
        XCTAssertEqual(clusters.assign(voice(0, 1, mix: 1), seconds: 2), "s1")
        // cos ≈ 0.27 to the first voice's center: another one.
        XCTAssertEqual(clusters.assign(voice(1, 2, mix: 1), seconds: 2), "s2")
    }

    func testVoicesAreCappedAtTheMaximum() {
        var clusters = LiveVoiceClusters(scheme: .voices)
        for axis in 0..<LiveVoiceClusters.maximumVoices { _ = clusters.assign(voice(axis), seconds: 2) }
        // Like none of them (cos ≈ 0.6 at best), yet it joins the closest instead of a ninth voice.
        var extra = [Float](repeating: 0.3, count: 8)
        extra[3] = 0.6
        XCTAssertEqual(clusters.assign(extra, seconds: 2), "s4")
        XCTAssertEqual(clusters.voices.count, LiveVoiceClusters.maximumVoices)
    }

    func testSpeakerIDs() {
        XCTAssertEqual((0..<3).map(LiveSpeakerIDs.channel("ch1").id(at:)), ["ch1", "ch1.2", "ch1.3"])
        XCTAssertEqual((0..<2).map(LiveSpeakerIDs.voices.id(at:)), ["s1", "s2"])
    }

    @MainActor
    func testKnownVoiceThresholdsAreThoseOfVoiceProfiles() {
        XCTAssertEqual(LiveVoiceMatch.threshold, VoiceProfiles.matchThreshold)
        XCTAssertEqual(LiveVoiceMatch.margin, VoiceProfiles.margin)
        XCTAssertEqual(LiveVoiceMatch.minimumSeconds, VoiceProfiles.minSeconds)
    }

    private func cluster(_ id: String, _ v: [Float], seconds: Double = 10) -> LiveVoiceClusters.Voice {
        let n = VoiceMath.normalized(v)
        return LiveVoiceClusters.Voice(id: id, sum: n, centroid: n, seconds: seconds)
    }

    func testKnownVoiceNamesAClearMatch() {
        let anna = LiveKnownVoice(id: "a", name: "Anna", voice: voice(0))
        let ben = LiveKnownVoice(id: "b", name: "Ben", voice: voice(1))
        let names = LiveVoiceMatch.names(for: [cluster("ch1", voice(0, 2, mix: 0.3)), cluster("ch1.2", voice(5))], known: [anna, ben])
        XCTAssertEqual(names, ["ch1": "Anna"])
    }

    func testKnownVoiceNeedsMarginSpeechAndIsUsedOnce() {
        let anna = LiveKnownVoice(id: "a", name: "Anna", voice: voice(0))
        let twin = LiveKnownVoice(id: "t", name: "Twin", voice: voice(0, 1, mix: 0.05))
        // Two known voices nearly alike: no clear winner.
        XCTAssertEqual(LiveVoiceMatch.names(for: [cluster("s1", voice(0))], known: [anna, twin]), [:])
        // Too little speech yet.
        XCTAssertEqual(LiveVoiceMatch.names(for: [cluster("s1", voice(0), seconds: 2)], known: [anna]), [:])
        // Two live voices like Anna: only the closer one is her.
        let names = LiveVoiceMatch.names(for: [cluster("s1", voice(0, 1, mix: 0.4)), cluster("s2", voice(0))], known: [anna])
        XCTAssertEqual(names, ["s2": "Anna"])
    }

    // MARK: Pauses

    private func tone(_ seconds: Double, level: Float) -> [Float] {
        (0..<Int(seconds * 16_000)).map { level * sin(Float($0) * 0.1) }
    }

    func testPauseAfterSpeechEndsAPiece() {
        let samples = tone(3, level: 0.2) + tone(0.8, level: 0.0005)
        let cut = RollingRecognizer.trailingPause(in: samples)
        XCTAssertNotNil(cut)
        XCTAssertLessThan(cut!, samples.count)
        XCTAssertGreaterThan(cut!, 3 * 16_000)
    }

    func testNoPauseWhileSpeakingOrInSilence() {
        XCTAssertNil(RollingRecognizer.trailingPause(in: tone(4, level: 0.2)))
        XCTAssertNil(RollingRecognizer.trailingPause(in: tone(4, level: 0.0005)), "silence alone is no pause after speech")
        // Too short a pause.
        XCTAssertNil(RollingRecognizer.trailingPause(in: tone(3, level: 0.2) + tone(0.3, level: 0.0005)))
    }

    func testSilenceHasNoSpeech() {
        XCTAssertFalse(RollingRecognizer.hasSpeech([Float](repeating: 0, count: 32_000)))
        XCTAssertTrue(RollingRecognizer.hasSpeech(tone(1, level: 0.1)))
    }

    // MARK: Track audio

    func testTrackAudioKeepsSamplesAndLevels() {
        let audio = TrackAudio()
        audio.append(tone(1, level: 0.5))
        audio.append([Float](repeating: 0, count: 16_000))
        XCTAssertEqual(audio.duration, 2, accuracy: 0.001)
        XCTAssertEqual(audio.samples(from: 0.5, to: 1.5).count, 16_000)
        let loud = audio.level(from: 0, to: 1)!
        let quiet = audio.level(from: 1, to: 2)!
        XCTAssertGreaterThan(loud - quiet, 40)
        XCTAssertNil(audio.level(from: 5, to: 6))
    }

    // MARK: Keeping the live transcript

    @MainActor
    func testLiveUtterancesBecomeSegmentsWithSpeakers() {
        let note = Note()
        note.speakerMode = .channels
        note.speakers = [
            Speaker(id: "ch0", name: "Me", colorIndex: 0),
            Speaker(id: "ch1", name: "Others", colorIndex: 1),
        ]
        let live = LiveTranscript(text: "Hi Hello Bye", utterances: [
            LiveUtterance(id: UUID(), track: 1, speakerID: "ch1", text: "Hi", isFinal: true, start: 0, end: 1),
            LiveUtterance(id: UUID(), track: 0, speakerID: "ch0", text: "Hello", isFinal: true, start: 1.5, end: 2),
            LiveUtterance(id: UUID(), track: 1, speakerID: "ch1.2", text: "Bye", isFinal: false, start: 3, end: 4),
        ])
        live.store(in: note, duration: 5)
        XCTAssertEqual(note.segments.map(\.speakerId), ["ch1", "ch0", "ch1.2"])
        XCTAssertEqual(note.speakers.map(\.id), ["ch0", "ch1", "ch1.2"])
        XCTAssertEqual(note.speakers.last?.name, "Speaker 3", "named as after recording, never by a live match")
        XCTAssertEqual(note.speakerMode, .channels)
    }

    @MainActor
    func testWithoutUtterancesTheTextIsOneSegment() {
        let note = Note()
        LiveTranscript(text: "Just this", utterances: []).store(in: note, duration: 9)
        XCTAssertEqual(note.segments.count, 1)
        XCTAssertNil(note.segments[0].speakerId)
        XCTAssertEqual(note.segments[0].end, 9)
    }
}
