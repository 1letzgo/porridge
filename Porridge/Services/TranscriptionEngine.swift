import AVFoundation
import FluidAudio
import Foundation

struct TranscriptionOutput: Sendable {
    let text: String
    let words: [Word]
}

/// Owns the FluidAudio models: Parakeet TDT v3 (0.6B) for ASR and the offline
/// pyannote pipeline for speaker diarization on single-channel recordings.
actor TranscriptionEngine {
    static let shared = TranscriptionEngine()
    static let asrVersion: AsrModelVersion = .v3

    private struct LoadedASR: @unchecked Sendable {
        let manager: AsrManager
        let models: AsrModels
    }

    private var asrTask: Task<LoadedASR, Error>?
    private var diarizer: OfflineDiarizerManager?

    nonisolated static var asrInstalled: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: asrVersion), version: asrVersion)
    }

    nonisolated static var diarizerInstalled: Bool {
        let dir = MLModelConfigurationUtils.defaultModelsDirectory(for: .diarizer)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return !contents.isEmpty
    }

    @discardableResult
    func loadASR(progress: ProgressHandler? = nil) async throws -> AsrManager {
        try await loadedASR(progress: progress).manager
    }

    private func loadedASR(progress: ProgressHandler? = nil) async throws -> LoadedASR {
        if let asrTask { return try await asrTask.value }
        let task = Task<LoadedASR, Error> {
            let models = try await AsrModels.downloadAndLoad(version: Self.asrVersion, progressHandler: progress)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return LoadedASR(manager: manager, models: models)
        }
        asrTask = task
        do {
            return try await task.value
        } catch {
            asrTask = nil
            throw error
        }
    }

    /// Deletes the downloaded Parakeet files; the model is loaded again (and downloaded) when needed.
    func deleteASR() {
        asrTask?.cancel()
        asrTask = nil
        try? FileManager.default.removeItem(at: AsrModels.defaultCacheDirectory(for: Self.asrVersion))
    }

    /// Deletes the downloaded speaker detection files.
    func deleteDiarizer() {
        diarizer = nil
        try? FileManager.default.removeItem(at: MLModelConfigurationUtils.defaultModelsDirectory(for: .diarizer))
    }

    func loadDiarizer() async throws {
        if diarizer != nil { return }
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await manager.prepareModels()
        if diarizer == nil { diarizer = manager }
    }

    /// Transcribes mono samples held in memory (inline dictation). No file round trip.
    func transcribe(samples: [Float], sampleRate: Double, language: Language?) async throws -> String {
        var samples = samples
        let minimum = Int(sampleRate)
        if samples.count < minimum { samples += [Float](repeating: 0, count: minimum - samples.count) }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return "" }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        if AppSettings.speechEngine == .apple {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
            return try await AppleSpeech.transcribe(url, language: language).text
        }
        let asr = try await loadASR()
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        do {
            return try await asr.transcribe(buffer, decoderState: &state, language: language).text
        } catch ASRError.invalidAudioData {
            return ""
        }
    }

    /// Transcribes a 16 kHz mono file and returns text plus word timings.
    func transcribe(_ url: URL, language: Language?) async throws -> TranscriptionOutput {
        if AppSettings.speechEngine == .apple {
            return try await AppleSpeech.transcribe(url, language: language)
        }
        let asr = try await loadASR()
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result: ASRResult
        do {
            result = try await asr.transcribe(url, decoderState: &state, language: language)
        } catch ASRError.invalidAudioData {
            return TranscriptionOutput(text: "", words: [])
        }
        let words = buildWordTimings(from: result.tokenTimings ?? []).map {
            Word(text: $0.word, start: $0.startTime, end: $0.endTime)
        }
        return TranscriptionOutput(text: result.text, words: words)
    }

    /// One voice print per time span (in seconds) of a 16 kHz mono file.
    func embed(_ url: URL, spans: [Range<Double>]) async throws -> [[Float]] {
        guard !spans.isEmpty else { return [] }
        try await loadDiarizer()
        guard let diarizer else { return [] }
        let (source, _) = try AudioSourceFactory().makeDiskBackedSource(from: url, targetSampleRate: 16_000)
        defer { source.cleanup() }
        return try await diarizer.embedSpans(audioSource: source, spans: spans)
    }

    func diarize(_ url: URL) async throws -> [DiarizedSegment] {
        try await loadDiarizer()
        guard let diarizer else { return [] }
        let result = try await diarizer.process(url)
        return result.segments.map {
            DiarizedSegment(
                speaker: $0.speakerId,
                start: Double($0.startTimeSeconds),
                end: Double($0.endTimeSeconds)
            )
        }
    }
}
