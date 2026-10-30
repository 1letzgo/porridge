import AVFoundation
import CoreMedia
import FluidAudio
import Foundation
import Speech

/// Apple's built-in on-device speech model (SpeechAnalyzer / SpeechTranscriber, iOS 26+).
enum AppleSpeech {
    static var isSupported: Bool {
        if #available(iOS 26, macOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    /// The locale to transcribe in. "Automatic" falls back to the device language,
    /// because Apple's model needs one concrete language.
    static func requestedLocale(for language: Language?) -> Locale {
        guard let language, language.rawValue != "auto" else { return Locale.current }
        return Locale(identifier: language.rawValue)
    }

    @available(iOS 26, macOS 26, *)
    private static func supportedLocale(for language: Language?) async throws -> Locale {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale(for: language)) else {
            throw AppleSpeechError.unsupportedLanguage
        }
        return locale
    }

    /// Whether the language pack for the selected language is on the device.
    static func isInstalled(language: Language?) async -> Bool {
        guard #available(iOS 26, macOS 26, *) else { return false }
        guard let locale = try? await supportedLocale(for: language) else { return false }
        let installed = await SpeechTranscriber.installedLocales
        return installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    }

    /// Downloads the language pack (if needed) and reserves it for this app.
    static func install(language: Language?, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard #available(iOS 26, macOS 26, *) else { throw AppleSpeechError.unavailable }
        let locale = try await supportedLocale(for: language)
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { p, _ in
                progress(p.fractionCompleted)
            }
            defer { observation.invalidate() }
            try await request.downloadAndInstall()
        }
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    // MARK: - Files

    static func transcribe(_ url: URL, language: Language?) async throws -> TranscriptionOutput {
        guard #available(iOS 26, macOS 26, *) else { throw AppleSpeechError.unavailable }
        let locale = try await supportedLocale(for: language)
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange]
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> TranscriptionOutput in
            var words: [Word] = []
            var parts: [String] = []
            for try await result in transcriber.results where result.isFinal {
                words += Self.words(from: result.text)
                parts.append(String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return TranscriptionOutput(text: parts.filter { !$0.isEmpty }.joined(separator: " "), words: words)
        }
        do {
            let file = try AVAudioFile(forReading: url)
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            return try await collector.value
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    /// Splits a result into words. Apple reports time ranges per run (often several words),
    /// so the run's time is distributed over its words by length.
    @available(iOS 26, macOS 26, *)
    private static func words(from text: AttributedString) -> [Word] {
        var words: [Word] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            let tokens = piece.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !tokens.isEmpty else { continue }
            let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self]
            let start = range?.start.seconds ?? words.last?.end ?? 0
            let end = range.map { $0.end.seconds } ?? start
            let total = Double(tokens.reduce(0) { $0 + $1.count })
            var cursor = start
            for token in tokens {
                let share = total > 0 ? (end - start) * Double(token.count) / total : 0
                words.append(Word(text: token, start: cursor, end: cursor + share))
                cursor += share
            }
        }
        return words
    }

    // MARK: - Live

    /// Streaming recognizer for the live preview while recording.
    @available(iOS 26, macOS 26, *)
    final class Live: @unchecked Sendable {
        private let transcriber: SpeechTranscriber
        private let analyzer: SpeechAnalyzer
        private let format: AVAudioFormat
        private let continuation: AsyncStream<AnalyzerInput>.Continuation
        private var converter: AVAudioConverter?
        private var resultsTask: Task<Void, Never>?
        private let onUpdate: @Sendable (_ confirmed: String, _ volatile: String) -> Void

        static func make(
            language: Language?,
            onUpdate: @escaping @Sendable (_ confirmed: String, _ volatile: String) -> Void
        ) async throws -> Live {
            let locale = try await AppleSpeech.supportedLocale(for: language)
            let transcriber = SpeechTranscriber(
                locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: []
            )
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw AppleSpeechError.unavailable
            }
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let live = Live(transcriber: transcriber, analyzer: analyzer, format: format, continuation: continuation, onUpdate: onUpdate)
            try await analyzer.start(inputSequence: stream)
            live.listen()
            return live
        }

        private init(
            transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer, format: AVAudioFormat,
            continuation: AsyncStream<AnalyzerInput>.Continuation,
            onUpdate: @escaping @Sendable (String, String) -> Void
        ) {
            self.transcriber = transcriber
            self.analyzer = analyzer
            self.format = format
            self.continuation = continuation
            self.onUpdate = onUpdate
        }

        private func listen() {
            let transcriber = transcriber
            let onUpdate = onUpdate
            resultsTask = Task {
                var confirmed = ""
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        if result.isFinal {
                            confirmed = [confirmed, text].filter { !$0.isEmpty }.joined(separator: " ")
                            onUpdate(confirmed, "")
                        } else {
                            onUpdate(confirmed, text)
                        }
                    }
                } catch {}
            }
        }

        /// Called from the audio thread in order, so it is not re-entrant.
        func feed(_ buffer: AVAudioPCMBuffer) {
            guard let converted = convert(buffer) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }

        private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            if buffer.format == format { return buffer }
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: format)
            }
            guard let converter else { return nil }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
            var provided = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if provided {
                    status.pointee = .noDataNow
                    return nil
                }
                provided = true
                status.pointee = .haveData
                return buffer
            }
            return error == nil && out.frameLength > 0 ? out : nil
        }

        func finish() async {
            continuation.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            await resultsTask?.value
        }

        func cancel() {
            continuation.finish()
            let analyzer = analyzer
            Task { await analyzer.cancelAndFinishNow() }
            resultsTask?.cancel()
        }
    }
}

enum AppleSpeechError: LocalizedError {
    case unavailable
    case unsupportedLanguage

    var errorDescription: String? {
        switch self {
        case .unavailable: "Apple speech recognition needs iOS 26 or newer."
        case .unsupportedLanguage: "Apple speech recognition does not support this language."
        }
    }
}
