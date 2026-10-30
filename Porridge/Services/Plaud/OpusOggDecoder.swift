import AVFoundation
import Foundation

enum OpusDecodeError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): "The recording could not be converted: \(message)"
        }
    }
}

/// Turns an Ogg Opus recording into an AAC `.m4a` file, which the rest of the app can read.
/// iOS and macOS decode Opus packets themselves; the Ogg container is read here.
enum OpusOggDecoder {
    struct Stream {
        var channels = 1
        var packets: [Data] = []
    }

    /// The Opus packets of an Ogg file (without the two header packets).
    static func demux(_ data: Data) throws -> Stream {
        let bytes = [UInt8](data)
        var stream = Stream()
        var current = Data()
        var index = 0
        var packetNumber = 0
        while index + 27 <= bytes.count {
            guard bytes[index] == 0x4F, bytes[index + 1] == 0x67, bytes[index + 2] == 0x67, bytes[index + 3] == 0x53 else {
                throw OpusDecodeError.invalid("damaged Ogg page")
            }
            let segmentCount = Int(bytes[index + 26])
            guard index + 27 + segmentCount <= bytes.count else { throw OpusDecodeError.invalid("truncated Ogg page") }
            var offset = index + 27 + segmentCount
            for segment in 0..<segmentCount {
                let length = Int(bytes[index + 27 + segment])
                guard offset + length <= bytes.count else { throw OpusDecodeError.invalid("truncated Ogg page") }
                current.append(contentsOf: bytes[offset..<(offset + length)])
                offset += length
                if length < 255 {
                    switch packetNumber {
                    case 0:
                        guard current.count >= 10, current.prefix(8) == Data("OpusHead".utf8) else {
                            throw OpusDecodeError.invalid("not Opus audio")
                        }
                        stream.channels = max(1, min(2, Int(current[current.startIndex + 9])))
                    case 1:
                        break
                    default:
                        stream.packets.append(current)
                    }
                    packetNumber += 1
                    current = Data()
                }
            }
            index = offset
        }
        guard !stream.packets.isEmpty else { throw OpusDecodeError.invalid("no audio in the file") }
        return stream
    }

    /// Writes the decoded audio as AAC to `url`. Returns the duration in seconds.
    @discardableResult
    static func decode(ogg: Data, to url: URL) throws -> Double {
        let stream = try demux(ogg)
        let channels = AVAudioChannelCount(stream.channels)

        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
            mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0
        )
        guard let inputFormat = AVAudioFormat(streamDescription: &description),
              let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: channels, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: pcmFormat)
        else { throw OpusDecodeError.invalid("this device cannot decode Opus") }

        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: Int(channels),
                AVEncoderBitRateKey: 64_000 * Int(channels),
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let batch = 100
        var frames: AVAudioFramePosition = 0
        var start = 0
        while start < stream.packets.count {
            let packets = Array(stream.packets[start..<min(start + batch, stream.packets.count)])
            start += packets.count

            let maxSize = packets.map(\.count).max() ?? 1
            let compressed = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: AVAudioPacketCount(packets.count), maximumPacketSize: max(maxSize, 1))
            var offset = 0
            for (i, packet) in packets.enumerated() {
                packet.withUnsafeBytes { raw in
                    compressed.data.advanced(by: offset).copyMemory(from: raw.baseAddress!, byteCount: packet.count)
                }
                compressed.packetDescriptions![i] = AudioStreamPacketDescription(
                    mStartOffset: Int64(offset), mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count)
                )
                offset += packet.count
            }
            compressed.packetCount = AVAudioPacketCount(packets.count)
            compressed.byteLength = UInt32(offset)

            guard let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(packets.count * 960 + 960)) else {
                throw OpusDecodeError.invalid("out of memory")
            }
            var supplied = false
            var failure: NSError?
            let status = converter.convert(to: pcm, error: &failure) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return compressed
            }
            if status == .error { throw OpusDecodeError.invalid(failure?.localizedDescription ?? "decoding failed") }
            if pcm.frameLength > 0 {
                try file.write(from: pcm)
                frames += AVAudioFramePosition(pcm.frameLength)
            }
        }
        return Double(frames) / 48_000
    }
}
