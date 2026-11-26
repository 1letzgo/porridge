import XCTest
@testable import Porridge

/// Speakers while recording: chat bubbles, the echo of the Mac's sound in the microphone, telling voices apart
/// live, naming them after known voices, and the pauses that end a live piece.
final class LiveSpeakerTests: XCTestCase {
    // MARK: Bubbles

    private func item(_ speaker: String?, _ text: String, at start: Double, final: Bool = true, sure: Bool = true) -> TranscriptBubbles.Item {
        TranscriptBubbles.Item(id: UUID(), speakerID: speaker, text: text, isFinal: final, start: start, end: start + 2, speakerIsSure: sure)
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

    func testOpenPieceWithAGuessedSpeakerIsANeutralBubbleOfItsOwn() {
        // B's open beginning took Speaker 3's id from the sentence before it: not hung onto that bubble.
        let items = [item("ch1", "Hello.", at: 0), item("ch1.2", "I think so.", at: 3), item("ch1.2", "Well actually", at: 5.3, final: false, sure: false)]
        let bubbles = TranscriptBubbles.bubbles(items, speakers: speakers)
        XCTAssertEqual(bubbles.count, 3)
        XCTAssertEqual(bubbles[1].text, "I think so.")
        XCTAssertNil(bubbles[2].speaker)
        XCTAssertNil(bubbles[2].speakerID)
        XCTAssertFalse(bubbles[2].showsName)
        XCTAssertEqual(bubbles[2].side, .leading)
        XCTAssertEqual(bubbles[2].id, items[2].id, "the piece keeps its bubble's id once it is confirmed")
    }

    func testOpenPieceOfASureSpeakerJoinsTheBubble() {
        let items = [item("ch1.2", "I think so.", at: 0), item("ch1.2", "and more", at: 2.3, final: false, sure: true)]
        let bubbles = TranscriptBubbles.bubbles(items, speakers: speakers)
        XCTAssertEqual(bubbles.count, 1)
        XCTAssertEqual(bubbles[0].speaker?.name, "Speaker 3")
    }

    func testConfirmedUtteranceWithAGuessedSpeakerStillFollowsItsTurn() {
        let items = [item("ch1.2", "I think so.", at: 0), item("ch1.2", "Yes.", at: 2.3, final: true, sure: false)]
        XCTAssertEqual(TranscriptBubbles.bubbles(items, speakers: speakers).count, 1)
    }

    func testSingleMicrophoneVoiceRecognizedAsTheUserIsOnTheRight() {
        let ids: Set<String> = ["s1", "s2"]
        func speaker(_ id: String, users: Set<String>) -> BubbleSpeaker {
            TranscriptBubbles.liveSpeaker(id: id, allIDs: ids, knownNames: ["s2": "Robin"], meName: "Me", othersName: "Others",
                                          isMeName: { _ in false }, userIDs: users)
        }
        XCTAssertFalse(speaker("s1", users: []).isMe)
        XCTAssertEqual(speaker("s1", users: []).name, "Speaker 1")
        XCTAssertTrue(speaker("s2", users: ["s2"]).isMe)
        XCTAssertEqual(speaker("s2", users: ["s2"]).name, "Robin")
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
        // The Mac's sound is never the user, not even by a known voice's name.
        XCTAssertEqual(speaker("ch1.2", all: ["ch1", "ch1.2"], known: ["ch1.2": "Dana"]), BubbleSpeaker(id: "ch1.2", name: "Speaker 3", colorIndex: 2, isMe: false))
        XCTAssertEqual(speaker("ch1", all: ["ch1"], known: ["ch1": "Me"]).name, "Others")
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

    func testALoneEchoWordInsideTheMacsSentenceIsAnEcho() {
        // "in." on the microphone, inside the others' sentence that says it, the Mac's sound much louder.
        XCTAssertTrue(LiveEcho.isEcho(
            microphone: "in.", microphoneLevel: -50, systemLevel: -22,
            system: ["I can help with the copy once the numbers are in."], insideSystem: true))
        XCTAssertTrue(LiveEcho.isInside(start: 26.9, end: 27.1, systemStart: 24.5, systemEnd: 27.1))
        XCTAssertFalse(LiveEcho.isInside(start: 28.0, end: 28.3, systemStart: 24.5, systemEnd: 27.1))
        // The user's own short reply, not said by the others, stays.
        XCTAssertFalse(LiveEcho.isEcho(
            microphone: "Okay.", microphoneLevel: -50, systemLevel: -22,
            system: ["I can help with the copy once the numbers are in."], insideSystem: true))
        // Said loudly by the user: stays.
        XCTAssertFalse(LiveEcho.isEcho(
            microphone: "in", microphoneLevel: -20, systemLevel: -22, system: ["the numbers are in"], insideSystem: true))
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

    func testTheUsersVoiceNeverNamesTheMacsSound() {
        let me = LiveKnownVoice(id: "m", name: "Me", voice: voice(0), isUser: true)
        let anna = LiveKnownVoice(id: "a", name: "Anna", voice: voice(1))
        // A voice of the Mac's sound like the user's: not named after the user.
        XCTAssertEqual(LiveVoiceMatch.names(for: [cluster("ch1.2", voice(0)), cluster("ch1", voice(1))], known: [me, anna]), ["ch1": "Anna"])
        // The voices of a single microphone may be the user.
        XCTAssertEqual(LiveVoiceMatch.names(for: [cluster("s1", voice(0))], known: [me, anna]), ["s1": "Me"])
        XCTAssertTrue(LiveVoiceMatch.isOthers("ch1"))
        XCTAssertTrue(LiveVoiceMatch.isOthers("ch1.3"))
        XCTAssertFalse(LiveVoiceMatch.isOthers("ch0"))
        XCTAssertFalse(LiveVoiceMatch.isOthers("s1"))
    }

    @MainActor
    func testTheUsersProfileIsNeverMatchedOnTheMacsSound() throws {
        let context = try TestStore.context()
        let mine = VoiceProfile(name: "Me", voice: voice(0), seconds: 60)
        let anna = VoiceProfile(name: "Anna", voice: voice(1), seconds: 60)
        context.insert(mine)
        context.insert(anna)
        let unnamed = Speaker(id: "ch1.2", name: "Speaker 3", colorIndex: 2, voice: VoiceMath.data(from: voice(0)), voiceSeconds: 20)
        let call = VoiceProfiles.match([unnamed], against: [mine, anna], refine: false, systemAudio: true)
        XCTAssertEqual(call[0].name, "Speaker 3")
        XCTAssertNil(call[0].profileID)
        // Two microphones (not the Mac's sound): the right one may be the user.
        let microphones = VoiceProfiles.match([unnamed], against: [mine, anna], refine: false)
        XCTAssertEqual(microphones[0].name, "Me")
        XCTAssertTrue(VoiceProfiles.isUser(id: "x", name: "me"))
        XCTAssertFalse(VoiceProfiles.isUser(id: "x", name: "Anna"))
    }

    // MARK: Short utterances

    func testShortUtteranceJoinsOnlyAClearlySimilarVoice() {
        var clusters = LiveVoiceClusters(scheme: .channel("ch1"))
        _ = clusters.assign(voice(0), seconds: 3)
        _ = clusters.assign(voice(1), seconds: 3)
        XCTAssertEqual(clusters.match(voice(1, 2, mix: 0.2)), "ch1.2", "cos 0.98")
        XCTAssertNil(clusters.match(voice(1, 2, mix: 1)), "cos 0.71: not sure enough for a short one")
        XCTAssertNil(clusters.match(voice(5)), "like none: no new voice from a short one")
        XCTAssertEqual(clusters.voices.count, 2)
        XCTAssertEqual(clusters.voices.map(\.seconds), [3, 3], "a short one teaches nothing")
    }

    private func short(_ start: Double, _ end: Double, _ measured: String? = nil) -> LiveShortUtterances.Item {
        LiveShortUtterances.Item(start: start, end: end, measured: measured)
    }

    func testShortUtterancesFollowTheirTurnOrHaveNoSpeaker() {
        let items = [
            short(0, 5, "ch1"),        // B
            short(5.6, 6.4),           // short, then C goes on at once: C
            short(6.6, 10, "ch1.2"),   // C
            short(13, 13.8),           // short, alone: no speaker
            short(16, 20, "ch1"),      // B
            short(20.5, 21.2),         // short, after B, nothing after: B
        ]
        XCTAssertEqual(LiveShortUtterances.speakers(items, firstID: "ch1"), ["ch1", "ch1.2", "ch1.2", nil, "ch1", "ch1"])
    }

    func testOnlyMeasuredOrSoleVoicesAreSure() {
        let items = [short(0, 5, "ch1"), short(5.6, 6.4), short(6.6, 10, "ch1.2"), short(13, 13.8)]
        XCTAssertEqual(LiveShortUtterances.assignments(items, firstID: "ch1").map(\.isSure), [true, false, true, false])
        XCTAssertEqual(LiveShortUtterances.assignments([short(0, 5, "s1"), short(5.2, 6)], firstID: "s1").map(\.isSure), [true, true],
                       "one voice so far: every utterance is that voice")
    }

    func testWithOneVoiceEverythingIsThatVoice() {
        XCTAssertEqual(LiveShortUtterances.speakers([short(0, 1), short(5, 9)], firstID: "ch1"), ["ch1", "ch1"])
        XCTAssertEqual(LiveShortUtterances.speakers([short(0, 1), short(5, 9, "s2")], firstID: "s1"), ["s2", "s2"])
    }

    // MARK: Voice budget

    func testMacMeasuresAtOnce() {
        let mac = LiveVoiceBudget.mac
        XCTAssertEqual(mac.decision(now: 10, lastStart: 9.9, lowPower: true, thermal: .critical), .now)
        XCTAssertEqual(mac.trimmed(Array(1...7)), Array(2...7))
    }

    func testMobileSpacesPrintsAndKeepsFewWaiting() {
        let mobile = LiveVoiceBudget.mobile
        XCTAssertEqual(mobile.decision(now: 10, lastStart: nil, lowPower: false, thermal: .nominal), .now)
        XCTAssertEqual(mobile.decision(now: 10, lastStart: 9, lowPower: false, thermal: .fair), .wait(0.5))
        XCTAssertEqual(mobile.decision(now: 10, lastStart: 8.5, lowPower: false, thermal: .nominal), .now)
        XCTAssertEqual(mobile.trimmed([1, 2, 3]), [2, 3], "the oldest is left out")
        XCTAssertEqual(mobile.trimmed([1]), [1])
    }

    func testMobilePausesUnderLoad() {
        let mobile = LiveVoiceBudget.mobile
        XCTAssertEqual(mobile.decision(now: 10, lastStart: nil, lowPower: true, thermal: .nominal), .paused)
        XCTAssertEqual(mobile.decision(now: 10, lastStart: nil, lowPower: false, thermal: .serious), .paused)
        XCTAssertEqual(mobile.decision(now: 10, lastStart: nil, lowPower: false, thermal: .critical), .paused)
    }

    // MARK: After Stop

    func testLiveVoicesKeepTheNamesAndColorsTheyGetAfterRecording() {
        XCTAssertEqual(LiveTranscript.addedSpeaker(id: "s2", existing: []), Speaker(id: "s2", name: "Speaker 2", colorIndex: 1))
        let first = LiveTranscript.addedSpeaker(id: "s1", existing: [])
        XCTAssertEqual(first, Speaker(id: "s1", name: "Speaker 1", colorIndex: 0))
        let taken = [Speaker(id: "x", name: "Speaker 1", colorIndex: 0)]
        XCTAssertEqual(LiveTranscript.addedSpeaker(id: "s1", existing: taken), Speaker(id: "s1", name: "Speaker 2", colorIndex: 1))
        XCTAssertEqual(LiveTranscript.addedSpeaker(id: "ch1.2", existing: taken), Speaker(id: "ch1.2", name: "Speaker 2", colorIndex: 1))
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

    /// The replayed call (`meeting-fixture-echo.wav`, microphone side): the user's last sentence (52.2–56.8 s) comes
    /// after the echo of the others (41–51.4 s, some 15–20 dB quieter) in one open piece the recognizer starts at
    /// 39.6. The open piece is always shown, and the echo rule judges it by the recognizer's start, never by a later one.
    func testAnOpenPieceIsAlwaysShownAndItsEchoRuleIsNotStricter() {
        let audio = TrackAudio()
        audio.append(tone(39.6, level: 0))
        audio.append(tone(0.6, level: 0.2))     // the end of the sentence before
        audio.append(tone(0.8, level: 0))
        audio.append(tone(10.4, level: 0.03))   // the echo of the Mac's sound
        audio.append(tone(0.8, level: 0))
        audio.append(tone(4.6, level: 0.25))    // the user's last sentence
        let voiced = audio.voicedStart(from: 39.6, to: 56.8)
        XCTAssertNotNil(voiced)
        let shown = LiveEcho.shownStart(recognizerStart: 39.6, end: 56.8, voiced: voiced)
        XCTAssertGreaterThanOrEqual(shown, 39.6)
        XCTAssertLessThanOrEqual(shown, 56.8)
        // Moved to the voice of the last sentence (nothing measured before it, the levels are only now there).
        let late = LiveEcho.shownStart(recognizerStart: 51.9, end: 56.8, voiced: audio.voicedStart(from: 51.9, to: 56.8))
        XCTAssertEqual(late, 52.2, accuracy: 0.15)
        // Nothing measured, all silence, or a start after its end: the recognizer's start, still shown.
        XCTAssertNil(audio.voicedStart(from: 70, to: 72))
        XCTAssertNil(audio.voicedStart(from: 51.5, to: 51.9))
        XCTAssertEqual(LiveEcho.shownStart(recognizerStart: 39.6, end: 56.8, voiced: nil), 39.6)
        XCTAssertEqual(LiveEcho.shownStart(recognizerStart: 39.6, end: 56.8, voiced: 60), 39.6)
        XCTAssertEqual(LiveEcho.shownStart(recognizerStart: 39.6, end: 56.8, voiced: .nan), 39.6)
        // The Mac's open piece runs on to 57: at the shown start the user's sentence lies "inside" it, at the
        // recognizer's it does not, so a single word of it does not hide the user's sentence.
        XCTAssertTrue(LiveEcho.isInside(start: late, end: 56.8, systemStart: 47.4, systemEnd: 57))
        let judged = LiveEcho.judgedStart(shownStart: late, recognizerStart: 39.6)
        XCTAssertEqual(judged, 39.6)
        XCTAssertFalse(LiveEcho.isInside(start: judged, end: 56.8, systemStart: 47.4, systemEnd: 57))
        XCTAssertEqual(LiveEcho.judgedStart(shownStart: 52.2, recognizerStart: nil), 52.2)
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
