import AVFoundation
import FluidAudio
import Observation

/// One stretch of speech in the live transcript, with its speaker and its place in the recording.
struct LiveUtterance: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The recognizer it came from (0: the microphone, 1: the Mac's sound).
    var track: Int
    /// "ch0" (the user), "ch1", "ch1.2"… (the Mac's sound), "s1", "s2"… (voices of one microphone); nil: unknown.
    var speakerID: String?
    var text: String
    /// Confirmed; otherwise the recognizer may still change it.
    var isFinal: Bool
    /// Seconds since the recording started (pauses left out, as in the file).
    var start: Double
    var end: Double
}

/// How the live transcript listens.
enum LiveLayout: Equatable, Sendable {
    /// One recognizer for the microphone (mixed to mono). `separatesVoices`: its voices are told apart live
    /// ("s1", "s2"…, `LiveSpeakers`); otherwise the utterances have no speaker.
    case single(separatesVoices: Bool)
    /// A call on the Mac: the microphone (the user, "ch0") and the Mac's sound (the others, "ch1"; with
    /// `separatesVoices` also "ch1.2"…) each with a recognizer of its own.
    case microphoneAndSystem(separatesVoices: Bool)
}

/// The live transcript when a recording stops, kept as the meeting's transcript until the final one replaces it.
struct LiveTranscript {
    var text = ""
    var utterances: [LiveUtterance] = []

    /// The utterances as segments with their speakers; speakers heard live that the note does not have yet are
    /// added with the default names they get after recording ("Speaker 3"), never a recognized name: the final
    /// transcript keeps speakers it finds under the same id, and a wrong name would be learned as a voice.
    func store(in note: Note, duration: Double) {
        let spoken = utterances.filter { !$0.text.isEmpty }
        guard !spoken.isEmpty else {
            if !text.isEmpty {
                note.segments = [TranscriptSegment(speakerId: nil, start: 0, end: duration, text: text)]
            }
            return
        }
        var speakers = note.speakers
        for id in spoken.compactMap(\.speakerID) where !speakers.contains(where: { $0.id == id }) {
            speakers.append(Speaker(id: id, name: "Speaker \(speakers.count + 1)", colorIndex: speakers.count))
        }
        note.segments = spoken.map {
            TranscriptSegment(speakerId: $0.speakerID, start: max(0, $0.start), end: max($0.start, $0.end), text: $0.text)
        }
        if speakers != note.speakers {
            note.speakers = speakers
            if note.speakerMode == .none { note.speakerMode = .diarized }
        }
    }
}

/// Shows what is being said while recording, as utterances with their speaker. Parakeet v3 re-transcribes the
/// running piece about once a second (see `RollingRecognizer`), or Apple's model streams it (`AppleSpeech.Live`);
/// the final transcript still comes from the batch pipeline.
///
/// A call on the Mac has a recognizer for each side (`LiveLayout.microphoneAndSystem`): what the microphone hears is
/// the user, what the Mac plays the others. The microphone also hears the others from the speakers: an utterance of
/// the microphone that repeats the Mac's sound while that was clearly louder is left out (`LiveEcho`).
@MainActor
@Observable
final class LiveTranscriber {
    enum Phase: Equatable {
        case idle
        case preparing
        case downloading(Double)
        case running
        case unavailable(String)
    }

    private(set) var phase: Phase = .idle
    /// The confirmed text (all utterances in order).
    private(set) var confirmed = ""
    /// The text still open.
    private(set) var volatile = ""
    /// What was said so far in order, with speakers; echoes of the Mac's sound are left out.
    private(set) var utterances: [LiveUtterance] = []
    /// Known voices recognized live: speaker id → name.
    private(set) var knownNames: [String: String] = [:]
    private(set) var layout: LiveLayout = .single(separatesVoices: false)

    var text: String {
        [confirmed, volatile].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The transcript so far, to keep when the recording stops.
    var transcript: LiveTranscript {
        LiveTranscript(text: text, utterances: utterances)
    }

    /// Hand this to the recorder; it receives mono copies of the microphone buffers.
    nonisolated let feed: @Sendable (AVAudioPCMBuffer) -> Void
    /// For a call on the Mac (`AudioRecorder.onChannelBuffers`): the microphone and the Mac's sound.
    nonisolated let feedChannels: @Sendable (AVAudioPCMBuffer, AVAudioPCMBuffer) -> Void

    @ObservationIgnored private let monoStream: AsyncStream<AVAudioPCMBuffer>
    @ObservationIgnored private let monoContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    @ObservationIgnored private let channelStream: AsyncStream<ChannelPair>
    @ObservationIgnored private let channelContinuation: AsyncStream<ChannelPair>.Continuation
    @ObservationIgnored private var tracks: [Track] = []
    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var voices: LiveSpeakers?
    @ObservationIgnored private var assigned: [UUID: String] = [:]
    @ObservationIgnored private var voiceBusy = false
    @ObservationIgnored private var voiceQueued: VoiceRequest?
    @ObservationIgnored private var echoes: [UUID: Bool] = [:]

    init() {
        let (mono, monoContinuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self, bufferingPolicy: .bufferingNewest(256))
        let (channels, channelContinuation) = AsyncStream.makeStream(of: ChannelPair.self, bufferingPolicy: .bufferingNewest(256))
        monoStream = mono
        self.monoContinuation = monoContinuation
        channelStream = channels
        self.channelContinuation = channelContinuation
        feed = { buffer in monoContinuation.yield(buffer) }
        feedChannels = { microphone, system in channelContinuation.yield(ChannelPair(microphone: microphone, system: system)) }
    }

    /// `knownVoices`: names for voices told apart live (`LiveSpeakers.knownVoices`).
    func start(language: Language?, layout: LiveLayout = .single(separatesVoices: false), knownVoices: [LiveKnownVoice] = []) async {
        guard phase == .idle else { return }
        self.layout = layout
        switch layout {
        case .single(let separates):
            channelContinuation.finish()
            tracks = [Track(index: 0, scheme: separates ? .voices : nil, fixedID: nil)]
        case .microphoneAndSystem(let separates):
            monoContinuation.finish()
            tracks = [
                Track(index: 0, scheme: nil, fixedID: SpeakerAssigner.leftChannelID),
                Track(index: 1, scheme: separates ? .channel(SpeakerAssigner.rightChannelID) : nil, fixedID: SpeakerAssigner.rightChannelID),
            ]
        }
        var schemes: [Int: LiveSpeakerIDs] = [:]
        for track in tracks { if let scheme = track.scheme { schemes[track.index] = scheme } }
        if !schemes.isEmpty { voices = LiveSpeakers(schemes: schemes, known: knownVoices) }

        if AppSettings.speechEngine == .apple {
            await startApple(language: language)
        } else {
            await startParakeet(language: language)
        }
    }

    private func pieceHandler(for track: Int) -> RollingRecognizer.OnPiece {
        { [weak self] text, start, end, isFinal in
            Task { @MainActor in self?.receive(track: track, text: text, start: start, end: end, isFinal: isFinal) }
        }
    }

    private func startParakeet(language: Language?) async {
        phase = TranscriptionEngine.asrInstalled ? .preparing : .downloading(0)
        do {
            try await ModelManager.shared.ensureLocalASR()
            let asr = try await TranscriptionEngine.shared.loadASR()
            var sinks: [Sink] = []
            for track in tracks {
                let rolling = RollingRecognizer(asr: asr, language: language, onPiece: pieceHandler(for: track.index))
                track.rolling = rolling
                await rolling.start()
                sinks.append(Sink(audio: track.audio, rolling: rolling, apple: nil))
            }
            startFeeding(sinks)
            phase = .running
        } catch {
            print("[live] start failed: \(error)")
            phase = .unavailable(error.localizedDescription)
        }
    }

    private func startApple(language: Language?) async {
        guard #available(iOS 26, macOS 26, *) else { return }
        phase = ModelManager.shared.asr == .ready ? .preparing : .downloading(0)
        do {
            try await ModelManager.shared.ensureLocalASR()
            var sinks: [Sink] = []
            for track in tracks {
                let live = try await AppleSpeech.Live.make(language: language, onPiece: pieceHandler(for: track.index))
                track.apple = live
                sinks.append(Sink(audio: track.audio, rolling: nil, apple: live))
            }
            startFeeding(sinks)
            phase = .running
        } catch {
            phase = .unavailable(error.localizedDescription)
        }
    }

    /// A single consumer per stream keeps the buffers in order. Every buffer is also kept at 16 kHz (`TrackAudio`)
    /// for the levels of the echo rule and the voice prints.
    private func startFeeding(_ sinks: [Sink]) {
        if sinks.count == 2 {
            let stream = channelStream
            feedTask = Task.detached {
                let converters = [AudioConverter(), AudioConverter()]
                for await pair in stream {
                    for (index, buffer) in [pair.microphone, pair.system].enumerated() {
                        await sinks[index].take(buffer, converter: converters[index])
                    }
                }
            }
        } else if let sink = sinks.first {
            let stream = monoStream
            feedTask = Task.detached {
                let converter = AudioConverter()
                for await buffer in stream {
                    await sink.take(buffer, converter: converter)
                }
            }
        }
    }

    func observeDownload(_ state: ModelManager.State) {
        if case .downloading(let progress) = state, case .downloading = phase {
            phase = .downloading(progress)
        }
    }

    /// Stops listening and returns the final live text.
    func finish() async -> String {
        monoContinuation.finish()
        channelContinuation.finish()
        await feedTask?.value
        var rollingText: [String] = []
        for track in tracks {
            if #available(iOS 26, macOS 26, *), let live = track.apple as? AppleSpeech.Live {
                await live.finish()
                track.apple = nil
            }
            if let rolling = track.rolling {
                rollingText.append(await rolling.finish())
                track.rolling = nil
            }
        }
        // The last pieces hop to the main actor like all others.
        await Task.yield()
        if text.isEmpty, tracks.count == 1, let last = rollingText.first, !last.isEmpty { return last }
        return text
    }

    func cancel() {
        monoContinuation.finish()
        channelContinuation.finish()
        feedTask?.cancel()
        for track in tracks {
            if #available(iOS 26, macOS 26, *), let live = track.apple as? AppleSpeech.Live { live.cancel() }
            track.apple = nil
            let rolling = track.rolling
            track.rolling = nil
            Task { await rolling?.cancel() }
        }
    }

    // MARK: Utterances

    private func receive(track index: Int, text: String, start: Double, end: Double, isFinal: Bool) {
        guard tracks.indices.contains(index) else { return }
        let track = tracks[index]
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The open piece's id goes on to its confirmed text, so its bubble stays where it is.
        let id = track.pending?.id ?? UUID()
        if isFinal {
            track.pending = nil
            if !text.isEmpty {
                let utterance = LiveUtterance(id: id, track: index, speakerID: track.fixedID, text: text, isFinal: true, start: start, end: end)
                track.finals.append(utterance)
                requestVoice(for: utterance, on: track)
            }
        } else {
            track.pending = text.isEmpty ? nil
                : LiveUtterance(id: id, track: index, speakerID: track.fixedID, text: text, isFinal: false, start: start, end: end)
        }
        rebuild()
    }

    private func rebuild() {
        var all: [LiveUtterance] = []
        for track in tracks {
            var list = track.finals
            if let pending = track.pending { list.append(pending) }
            if let scheme = track.scheme {
                // Short utterances, and those not measured yet, keep the voice before them.
                var current = scheme.id(at: 0)
                for index in list.indices {
                    if let id = assigned[list[index].id] { current = id }
                    list[index].speakerID = current
                }
            }
            all += list
        }
        if case .microphoneAndSystem = layout, tracks.count == 2 {
            all = all.filter { !($0.track == 0 && isEcho($0)) }
        }
        all.sort { $0.start != $1.start ? $0.start < $1.start : $0.track < $1.track }
        utterances = all
        confirmed = all.filter(\.isFinal).map(\.text).joined(separator: " ")
        volatile = all.filter { !$0.isFinal }.map(\.text).joined(separator: " ")
    }

    /// Whether an utterance of the microphone repeats the Mac's sound. Decided again while the Mac's side may still
    /// add text around it, then kept.
    private func isEcho(_ utterance: LiveUtterance) -> Bool {
        if let known = echoes[utterance.id] { return known }
        let system = tracks[1]
        var others = system.finals
        if let pending = system.pending { others.append(pending) }
        let near = others.filter { $0.end >= utterance.start - LiveEcho.window && $0.start <= utterance.end + LiveEcho.window }
        let echo = LiveEcho.isEcho(
            microphone: utterance.text,
            microphoneLevel: tracks[0].audio.level(from: utterance.start, to: utterance.end),
            systemLevel: system.audio.level(from: utterance.start, to: utterance.end),
            system: near.map(\.text)
        )
        let settled = utterance.isFinal && system.audio.duration > utterance.end + LiveEcho.settleSeconds
        if settled { echoes[utterance.id] = echo }
        return echo
    }

    // MARK: Voices

    private struct VoiceRequest {
        let utterance: UUID
        let track: Int
        let samples: [Float]
    }

    /// Measures the voice of a confirmed utterance that is long enough. One at a time: while one is measured, only the
    /// newest waiting one is kept, the others keep the voice before them.
    private func requestVoice(for utterance: LiveUtterance, on track: Track) {
        guard voices != nil, track.scheme != nil, utterance.end - utterance.start >= LiveSpeakers.minimumSeconds else { return }
        let from = max(utterance.start, utterance.end - LiveSpeakers.maximumSeconds)
        let samples = track.audio.samples(from: from, to: utterance.end)
        guard Double(samples.count) >= LiveSpeakers.minimumSeconds * Double(TrackAudio.sampleRate) * 0.8 else { return }
        let request = VoiceRequest(utterance: utterance.id, track: track.index, samples: samples)
        if voiceBusy {
            voiceQueued = request
        } else {
            measure(request)
        }
    }

    private func measure(_ request: VoiceRequest) {
        guard let voices else { return }
        voiceBusy = true
        Task { [weak self] in
            let assignment = await voices.assign(request.samples, track: request.track)
            guard let self else { return }
            self.voiceBusy = false
            if let assignment {
                self.assigned[request.utterance] = assignment.speakerID
                if self.knownNames != assignment.knownNames { self.knownNames = assignment.knownNames }
                self.rebuild()
            }
            if let next = self.voiceQueued {
                self.voiceQueued = nil
                self.measure(next)
            }
        }
    }
}

/// One recognizer's side of the live transcript.
@MainActor
private final class Track {
    let index: Int
    /// How its voices are told apart; nil: all its utterances are `fixedID`.
    let scheme: LiveSpeakerIDs?
    let fixedID: String?
    let audio = TrackAudio()
    var finals: [LiveUtterance] = []
    var pending: LiveUtterance?
    var rolling: RollingRecognizer?
    var apple: AnyObject?

    init(index: Int, scheme: LiveSpeakerIDs?, fixedID: String?) {
        self.index = index
        self.scheme = scheme
        self.fixedID = fixedID
    }
}

private struct ChannelPair: @unchecked Sendable {
    let microphone: AVAudioPCMBuffer
    let system: AVAudioPCMBuffer
}

/// Where one track's buffers go, from the feeding task.
private struct Sink: @unchecked Sendable {
    let audio: TrackAudio
    let rolling: RollingRecognizer?
    let apple: AnyObject?

    func take(_ buffer: AVAudioPCMBuffer, converter: AudioConverter) async {
        let samples: [Float]
        do {
            samples = try converter.resampleBuffer(buffer)
        } catch {
            print("[live] resample failed (\(buffer.format)): \(error)")
            return
        }
        audio.append(samples)
        if let rolling {
            await rolling.append(samples)
        } else if #available(iOS 26, macOS 26, *), let live = apple as? AppleSpeech.Live {
            live.feed(buffer)
        }
    }
}

/// The recent sound of one track at 16 kHz (for voice prints) and its level in 100 ms steps (for the echo rule).
final class TrackAudio: @unchecked Sendable {
    static let sampleRate = 16_000
    /// Samples kept for voice prints.
    static let keptSeconds = 60.0
    private static let frame = sampleRate / 10

    private let lock = NSLock()
    private var samples: [Float] = []
    /// The position of `samples[0]` in everything appended.
    private var offset = 0
    private var total = 0
    /// dBFS per 100 ms since the start.
    private var levels: [Float] = []
    private var frameSum: Float = 0
    private var frameCount = 0

    /// Seconds appended so far.
    var duration: Double {
        lock.withLock { Double(total) / Double(Self.sampleRate) }
    }

    func append(_ new: [Float]) {
        lock.withLock {
            samples.append(contentsOf: new)
            total += new.count
            let keep = Int(Self.keptSeconds) * Self.sampleRate
            if samples.count > keep + keep / 2 {
                let drop = samples.count - keep
                samples.removeFirst(drop)
                offset += drop
            }
            for sample in new {
                frameSum += sample * sample
                frameCount += 1
                if frameCount == Self.frame {
                    levels.append(LiveEcho.decibels(rms: (frameSum / Float(Self.frame)).squareRoot()))
                    frameSum = 0
                    frameCount = 0
                }
            }
        }
    }

    /// The samples between two times (only what is still kept).
    func samples(from start: Double, to end: Double) -> [Float] {
        lock.withLock {
            let rate = Double(Self.sampleRate)
            let from = max(Int(start * rate), offset) - offset
            let to = min(Int(end * rate), offset + samples.count) - offset
            guard to > from else { return [] }
            return Array(samples[from..<to])
        }
    }

    /// The average level (dBFS) between two times; nil when nothing was measured there.
    func level(from start: Double, to end: Double) -> Float? {
        lock.withLock {
            let from = max(0, Int(start * 10))
            let to = min(levels.count, Int((end * 10).rounded(.up)))
            guard to > from else { return nil }
            let slice = levels[from..<to]
            return slice.reduce(0, +) / Float(slice.count)
        }
    }
}

/// The microphone of a call also hears the others from the Mac's speakers. Such an echo is recognized twice: once
/// from the Mac's sound, once from the microphone. A microphone utterance is an echo when, at the same time, the
/// Mac's sound was clearly louder and its text says the same. In doubt (too short, no levels) it is kept.
enum LiveEcho {
    /// The Mac's sound must be at least this much louder (dB) than the microphone.
    static let louder: Float = 6
    /// At least this share of the microphone's words must be in the Mac's text at that time.
    static let sameWords = 0.6
    /// Utterances this many seconds apart still count as the same time.
    static let window = 1.5
    /// Echoes with fewer words are kept (a short "yes" may be the user's).
    static let minimumWords = 2
    /// Decided for good once the Mac's sound has gone on this long after the utterance.
    static let settleSeconds = 8.0

    static func decibels(rms: Float) -> Float {
        20 * log10(max(rms, 1e-6))
    }

    /// The words of a text, lowercased, without punctuation.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// The share of `microphone`'s words that are in `system` (0…1).
    static func similarity(microphone: String, system: String) -> Double {
        let mine = words(microphone)
        guard !mine.isEmpty else { return 0 }
        let theirs = Set(words(system))
        return Double(mine.filter(theirs.contains).count) / Double(mine.count)
    }

    static func isEcho(microphone: String, microphoneLevel: Float?, systemLevel: Float?, system: [String]) -> Bool {
        guard words(microphone).count >= minimumWords,
              let microphoneLevel, let systemLevel,
              systemLevel - microphoneLevel >= louder,
              !system.isEmpty else { return false }
        return similarity(microphone: microphone, system: system.joined(separator: " ")) >= sameWords
    }
}
