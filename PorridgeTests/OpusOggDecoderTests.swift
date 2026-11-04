import XCTest
@testable import Porridge

final class OpusOggDecoderTests: XCTestCase {
    private func le(_ value: UInt64, _ count: Int) -> [UInt8] { (0..<count).map { UInt8((value >> (8 * UInt64($0))) & 0xff) } }

    /// The demuxer reads no checksums, so plain pages are enough.
    private func ogg(_ packets: [[UInt8]]) -> Data {
        let head = Array("OpusHead".utf8) + [1, 1] + le(312, 2) + le(16_000, 4) + [0, 0, 0]
        let tags = Array("OpusTags".utf8) + le(0, 4) + le(0, 4)
        var out: [UInt8] = []
        func page(_ list: [[UInt8]], type: UInt8) {
            let lacing = list.flatMap { Array(repeating: UInt8(255), count: $0.count / 255) + [UInt8($0.count % 255)] }
            out += Array("OggS".utf8) + [0, type] + le(0, 8) + le(1, 4) + le(0, 4) + le(0, 4) + [UInt8(lacing.count)] + lacing + list.flatMap { $0 }
        }
        page([head], type: 2)
        page([tags], type: 0)
        var index = 0
        while index < packets.count {
            page(Array(packets[index..<min(index + 50, packets.count)]), type: 0)
            index += 50
        }
        return Data(out)
    }

    private func frames() -> [[UInt8]] {
        var generator = SystemRandomNumberGenerator()
        return (0..<400).map { _ in [0xB8] + (0..<79).map { _ in UInt8.random(in: 0...255, using: &generator) } }
    }

    private func duration(_ packets: [[UInt8]]) throws -> Double {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        return try OpusOggDecoder.decode(ogg: ogg(packets), to: url)
    }

    func testGoodRecordingConverts() throws {
        XCTAssertEqual(try duration(frames()), 8, accuracy: 0.2)
    }

    /// One bad packet must not lose the recording.
    func testInvalidPacketDoesNotStopTheConversion() throws {
        var packets = frames()
        packets[200] = [0xBB, 0] + Array(repeating: 0, count: 78)
        XCTAssertEqual(try duration(packets), 8, accuracy: 0.2)
    }
}
