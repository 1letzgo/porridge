import Accelerate
import AVFoundation

/// Short-time energy per channel, used to decide which microphone a word came from.
struct ChannelEnergy: Sendable {
    let frameDuration: Double
    let left: [Float]
    let right: [Float]
}

struct PreparedAudio: Sendable {
    /// 16 kHz mono mix, ready for ASR and diarization. Delete when done.
    let monoURL: URL
    let duration: Double
    let channelEnergy: ChannelEnergy?
}

enum AudioPreprocessor {
    static let energyFrameDuration = 0.05

    /// Streams the recording once: mixes it down to 16 kHz mono and, for split-stereo
    /// recordings, measures the energy of both channels.
    static func prepare(source: URL, measureChannels: Bool) throws -> PreparedAudio {
        let input = try AVAudioFile(forReading: source)
        let inFormat = input.processingFormat
        let channels = Int(inFormat.channelCount)
        let sampleRate = inFormat.sampleRate
        let measure = measureChannels && channels >= 2

        guard let monoNative = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let mono16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoNative, to: mono16k)
        else { throw ASRPipelineError.audioFormat }

        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let output = try AVAudioFile(
            forWriting: outURL,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        let chunk = AVAudioFrameCount(max(4096, sampleRate))
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk),
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoNative, frameCapacity: chunk)
        else { throw ASRPipelineError.audioFormat }

        let ratio = 16_000 / sampleRate
        func convert(_ buffer: AVAudioPCMBuffer?, endOfStream: Bool) throws {
            let capacity = AVAudioFrameCount(Double(buffer?.frameLength ?? 0) * ratio) + 4096
            guard let out = AVAudioPCMBuffer(pcmFormat: mono16k, frameCapacity: capacity) else { return }
            var provided = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if let buffer, !provided {
                    provided = true
                    inputStatus.pointee = .haveData
                    return buffer
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if status == .error, let error { throw error }
            if out.frameLength > 0 { try output.write(from: out) }
        }

        let frameLength = max(1, Int(sampleRate * energyFrameDuration))
        var left: [Float] = []
        var right: [Float] = []
        var accLeft: Float = 0
        var accRight: Float = 0
        var accCount = 0
        var totalFrames: Int64 = 0

        while input.framePosition < input.length {
            try input.read(into: inBuffer, frameCount: chunk)
            let n = Int(inBuffer.frameLength)
            guard n > 0, let src = inBuffer.floatChannelData, let dst = monoBuffer.floatChannelData else { break }
            totalFrames += Int64(n)

            if channels == 1 {
                dst[0].update(from: src[0], count: n)
            } else {
                vDSP_vadd(src[0], 1, src[1], 1, dst[0], 1, vDSP_Length(n))
                for channel in 2..<max(2, channels) {
                    vDSP_vadd(dst[0], 1, src[channel], 1, dst[0], 1, vDSP_Length(n))
                }
                var scale = 1 / Float(channels)
                vDSP_vsmul(dst[0], 1, &scale, dst[0], 1, vDSP_Length(n))
            }
            monoBuffer.frameLength = AVAudioFrameCount(n)

            if measure {
                let l = src[0], r = src[1]
                for i in 0..<n {
                    accLeft += l[i] * l[i]
                    accRight += r[i] * r[i]
                    accCount += 1
                    if accCount == frameLength {
                        left.append(accLeft / Float(frameLength))
                        right.append(accRight / Float(frameLength))
                        accLeft = 0
                        accRight = 0
                        accCount = 0
                    }
                }
            }

            try convert(monoBuffer, endOfStream: false)
        }
        try convert(nil, endOfStream: true)

        if measure, accCount > 0 {
            left.append(accLeft / Float(accCount))
            right.append(accRight / Float(accCount))
        }

        return PreparedAudio(
            monoURL: outURL,
            duration: Double(totalFrames) / sampleRate,
            channelEnergy: measure
                ? ChannelEnergy(frameDuration: Double(frameLength) / sampleRate, left: left, right: right)
                : nil
        )
    }
}

enum ASRPipelineError: LocalizedError {
    case audioFormat
    case missingAudio

    var errorDescription: String? {
        switch self {
        case .audioFormat: "This audio format is not supported."
        case .missingAudio: "The recording is not available on this device."
        }
    }
}
