import AVFoundation
import XCTest
@testable import Porridge

/// The Mac's sound of a call (right channel) is kept on its own for telling the others' voices apart.
final class RightChannelTests: XCTestCase {
    func testRightChannelIsWrittenAlone() throws {
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
                data[0][i] = 0                                            // left: silence (the user)
                data[1][i] = 0.5 * sin(Float(i) * 2 * .pi * 440 / Float(rate)) // right: a tone (the others)
            }
            try file.write(from: buffer)
        }
        let prepared = try AudioPreprocessor.prepare(source: url, measureChannels: true, keepRightChannel: true)
        defer {
            try? FileManager.default.removeItem(at: prepared.monoURL)
            if let right = prepared.rightURL { try? FileManager.default.removeItem(at: right) }
        }
        let rightURL = try XCTUnwrap(prepared.rightURL)
        let right = try AVAudioFile(forReading: rightURL)
        let mix = try AVAudioFile(forReading: prepared.monoURL)
        XCTAssertEqual(right.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(right.length, mix.length, accuracy: 64)
        XCTAssertGreaterThan(right.length, 15_000)
        // The right channel alone is louder than the mix it is half of.
        func peak(_ file: AVAudioFile) throws -> Float {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            return (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0
        }
        XCTAssertGreaterThan(try peak(right), try peak(mix) * 1.5)

        let plain = try AudioPreprocessor.prepare(source: url, measureChannels: true)
        defer { try? FileManager.default.removeItem(at: plain.monoURL) }
        XCTAssertNil(plain.rightURL)
    }
}
