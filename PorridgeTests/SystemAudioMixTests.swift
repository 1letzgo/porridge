import AVFoundation
import XCTest
@testable import Porridge

/// The Mac's sound next to the microphone: the queue between the two clocks, the stereo buffer, and telling
/// several people apart on the others' channel.
final class SystemAudioMixTests: XCTestCase {
    // MARK: SampleFIFO

    func testSilenceUntilTheCushionIsThere() {
        let fifo = SampleFIFO(target: 4, slack: 100)
        fifo.push([1, 2, 3])
        XCTAssertEqual(fifo.pull(count: 2), [0, 0])
        fifo.push([4, 5, 6])
        // 6 samples >= target 4 + 2 requested: starts, keeping the cushion.
        XCTAssertEqual(fifo.pull(count: 2), [1, 2])
        XCTAssertEqual(fifo.count, 4)
    }

    func testRunningDryPadsWithSilenceAndWaitsAgain() {
        let fifo = SampleFIFO(target: 0, slack: 100)
        fifo.push([1, 2])
        XCTAssertEqual(fifo.pull(count: 4), [1, 2, 0, 0])
        fifo.push([3])
        XCTAssertEqual(fifo.pull(count: 1), [3])
    }

    func testBacklogIsDroppedDownToTheCushion() {
        let fifo = SampleFIFO(target: 2, slack: 3)
        fifo.push((1...20).map(Float.init))
        // 20 > 2 + 3 + 2: the oldest are dropped, the newest 2 + 2 stay; then 2 are read.
        XCTAssertEqual(fifo.pull(count: 2), [17, 18])
        XCTAssertEqual(fifo.count, 2)
    }

    func testResetStartsOver() {
        let fifo = SampleFIFO(target: 0, slack: 10)
        fifo.push([1, 2, 3])
        fifo.reset()
        XCTAssertEqual(fifo.count, 0)
        XCTAssertEqual(fifo.pull(count: 2), [0, 0])
    }

    func testLongRunKeepsOrder() {
        let fifo = SampleFIFO(target: 3, slack: 1_000)
        var next: Float = 1
        var read: [Float] = []
        for _ in 0..<5_000 {
            fifo.push([next, next + 1])
            next += 2
            read += fifo.pull(count: 2)
        }
        let started = read.drop { $0 == 0 }
        XCTAssertEqual(Array(started.prefix(4)), [1, 2, 3, 4])
        XCTAssertTrue(zip(started, started.dropFirst()).allSatisfy { $1 == $0 + 1 })
    }

    // MARK: Stereo

    func testStereoPutsMicrophoneLeftAndSoundRight() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let mic = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        mic.frameLength = 3
        for i in 0..<3 {
            mic.floatChannelData![0][i] = 0.2
            mic.floatChannelData![1][i] = 0.4
        }
        let fifo = SampleFIFO(target: 0, slack: 100)
        fifo.push([0.5, 0.6, 0.7])
        let stereo = try XCTUnwrap(SystemAudioMix.stereo(microphone: mic, fifo: fifo))
        XCTAssertEqual(stereo.format.channelCount, 2)
        XCTAssertEqual(stereo.frameLength, 3)
        XCTAssertEqual(stereo.floatChannelData![0][1], 0.3, accuracy: 1e-6)
        XCTAssertEqual(stereo.floatChannelData![1][0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(stereo.floatChannelData![1][2], 0.7, accuracy: 1e-6)
    }

    func testRecognizesSystemAudioMeetings() {
        XCTAssertTrue(SystemAudioMix.isSystemAudio(inputName: SystemAudioMix.inputName))
        XCTAssertFalse(SystemAudioMix.isSystemAudio(inputName: "Microphone"))
        XCTAssertFalse(SystemAudioMix.isSystemAudio(inputName: nil))
    }

    func testOthersAreSplitOnlyWhileUnnamed() {
        XCTAssertTrue(SystemAudioMix.splitsOthers(Speaker(id: "ch1", name: "Others", colorIndex: 1)))
        XCTAssertTrue(SystemAudioMix.splitsOthers(Speaker(id: "ch1", name: "Speaker 2", colorIndex: 1)))
        XCTAssertFalse(SystemAudioMix.splitsOthers(Speaker(id: "ch1", name: "Anna", colorIndex: 1)))
        var known = Speaker(id: "ch1", name: "Speaker 2", colorIndex: 1)
        known.profileID = UUID().uuidString
        XCTAssertFalse(SystemAudioMix.splitsOthers(known))
    }

    // MARK: Splitting the others

    private func words(_ count: Int, length: Double = 1) -> [Word] {
        (0..<count).map { Word(text: "w\($0)", start: Double($0) * length, end: Double($0 + 1) * length) }
    }

    func testSplitsTheOthersIntoVoices() {
        let words = words(40)
        // 0..<10 me, 10..<25 first other, 25..<40 second other.
        let ids: [String?] = (0..<40).map { $0 < 10 ? "ch0" : "ch1" }
        let segments = [
            DiarizedSegment(speaker: "A", start: 0, end: 10),
            DiarizedSegment(speaker: "B", start: 10, end: 25),
            DiarizedSegment(speaker: "C", start: 25, end: 40),
        ]
        let split = SpeakerAssigner.splitChannel(words, ids: ids, channel: "ch1", segments: segments)
        XCTAssertEqual(split.added, ["ch1.2"])
        XCTAssertEqual(split.ids[5], "ch0")
        XCTAssertEqual(split.ids[12], "ch1")
        XCTAssertEqual(split.ids[30], "ch1.2")
    }

    func testOneVoiceAndShortFalseSplitsChangeNothing() {
        let words = words(30)
        let ids: [String?] = (0..<30).map { $0 < 10 ? "ch0" : "ch1" }
        let one = SpeakerAssigner.splitChannel(words, ids: ids, channel: "ch1", segments: [DiarizedSegment(speaker: "B", start: 0, end: 30)])
        XCTAssertEqual(one.ids, ids)
        XCTAssertTrue(one.added.isEmpty)

        // Three seconds of a "second voice" is too little to be a person of its own.
        let short = SpeakerAssigner.splitChannel(words, ids: ids, channel: "ch1", segments: [
            DiarizedSegment(speaker: "B", start: 10, end: 20),
            DiarizedSegment(speaker: "X", start: 20, end: 23),
            DiarizedSegment(speaker: "B", start: 23, end: 30),
        ])
        XCTAssertTrue(short.added.isEmpty)
        XCTAssertEqual(short.ids, ids)
    }

    func testMyWordsNeverMoveToTheOthers() {
        let words = words(30)
        // A single word of mine between the others' words stays mine.
        var ids: [String?] = Array(repeating: "ch1", count: 30)
        ids[15] = "ch0"
        let segments = [
            DiarizedSegment(speaker: "B", start: 0, end: 15),
            DiarizedSegment(speaker: "C", start: 15, end: 30),
        ]
        let split = SpeakerAssigner.splitChannel(words, ids: ids, channel: "ch1", segments: segments)
        XCTAssertEqual(split.ids[15], "ch0")
        XCTAssertEqual(split.added, ["ch1.2"])
    }

    // MARK: The rate the Mac's sound really arrives at

    /// Feeds `seconds` of 512-frame buffers arriving at `rate`, starting at `start`; returns the changes reported.
    private func feed(_ measure: inout DeliveredRate, rate: Double, seconds: Double, from start: Double, buffer: Int = 512) -> [Double] {
        var changes: [Double] = []
        let count = Int(seconds * rate) / buffer
        for index in 0...count {
            if let new = measure.add(frames: buffer, at: start + Double(index * buffer) / rate) { changes.append(new) }
        }
        return changes
    }

    func testTheRateTheTapClaimsIsKeptWhenItIsRight() {
        var measure = DeliveredRate(rate: 48_000)
        XCTAssertEqual(feed(&measure, rate: 48_000, seconds: 5, from: 100), [])
        XCTAssertEqual(measure.rate, 48_000)
    }

    /// The output at 44.1 kHz (or AirPods at 24 or 16 kHz in a call) while the tap still says 48 kHz: read at 48 kHz
    /// the others came out at the wrong speed and full of gaps, and were hardly transcribed.
    func testAnotherDeliveredRateIsFoundWithinTheWindow() {
        for real in [44_100.0, 24_000, 16_000] {
            var measure = DeliveredRate(rate: 48_000)
            XCTAssertEqual(feed(&measure, rate: real, seconds: 1.2, from: 50), [real], "\(real)")
            XCTAssertEqual(measure.rate, real)
        }
    }

    func testARateChangeInTheMiddleIsFollowed() {
        var measure = DeliveredRate(rate: 48_000)
        XCTAssertEqual(feed(&measure, rate: 48_000, seconds: 3, from: 0), [])
        XCTAssertEqual(feed(&measure, rate: 24_000, seconds: 3, from: 3.01), [24_000])
        XCTAssertEqual(measure.rate, 24_000)
    }

    func testAGapIsNoRate() {
        var measure = DeliveredRate(rate: 48_000)
        _ = feed(&measure, rate: 48_000, seconds: 0.5, from: 0)
        // The device stalled for two seconds: half a second of frames over 2.5 s is no standard rate.
        XCTAssertNil(measure.add(frames: 512, at: 2.5))
        XCTAssertEqual(measure.rate, 48_000)
        XCTAssertEqual(feed(&measure, rate: 48_000, seconds: 2, from: 2.51), [])
    }

    func testSnapping() {
        XCTAssertEqual(DeliveredRate.snap(47_712), 48_000)
        XCTAssertEqual(DeliveredRate.snap(44_350), 44_100)
        XCTAssertEqual(DeliveredRate.snap(24_150), 24_000)
        XCTAssertNil(DeliveredRate.snap(36_000))
        XCTAssertNil(DeliveredRate.snap(0))
    }
}
