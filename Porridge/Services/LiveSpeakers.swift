import FluidAudio
import Foundation
import SwiftData

/// Telling voices apart while recording, deliberately simple: every confirmed utterance of at least
/// `minimumSeconds` gets a voice print, compared with the voices heard so far in this meeting (`LiveVoiceClusters`);
/// shorter ones keep the voice before them (`LiveTranscriber`). Known voices (`VoiceProfile`) only give a name;
/// nothing is learned live. The final transcript's speakers still come from the recording (`ProcessingService`).
///
/// Its own `OfflineDiarizerManager` (the processing's one in `TranscriptionEngine` may be busy with another
/// meeting); one voice print at a time, off the main thread. Only when the speaker detection model is on the
/// device: nothing is downloaded for this.
actor LiveSpeakers {
    /// Utterances shorter than this keep the voice before them.
    static let minimumSeconds = 1.5
    /// Longer utterances are measured on their last this many seconds.
    static let maximumSeconds = 10.0

    /// Whether voices are told apart live on this device. The iPhone runs the live speech model next to the
    /// recording already; until its load is measured, voices are only told apart after recording there.
    #if os(macOS)
    static let isEnabledOnThisDevice = true
    #else
    static let isEnabledOnThisDevice = false
    #endif

    /// Whether voices are told apart live: on this device, with speaker detection on and its model on the device.
    static var isAvailable: Bool {
        isEnabledOnThisDevice && AppSettings.speakerDetectionEnabled && TranscriptionEngine.diarizerInstalled
    }

    struct Assignment: Sendable {
        let speakerID: String
        /// Known voices recognized so far: speaker id → name.
        let knownNames: [String: String]
    }

    private let schemes: [Int: LiveSpeakerIDs]
    private let known: [LiveKnownVoice]
    private var clusters: [Int: LiveVoiceClusters] = [:]
    private var manager: OfflineDiarizerManager?
    private var failed = false

    /// `schemes`: how the voices of each track (by index) are named.
    init(schemes: [Int: LiveSpeakerIDs], known: [LiveKnownVoice]) {
        self.schemes = schemes
        self.known = known
    }

    /// The voice of `samples` (16 kHz mono) on `track`; nil when no voice print could be made.
    func assign(_ samples: [Float], track: Int) async -> Assignment? {
        guard let scheme = schemes[track], !failed, !samples.isEmpty else { return nil }
        guard let embedding = await embed(samples) else { return nil }
        var voices = clusters[track] ?? LiveVoiceClusters(scheme: scheme)
        let id = voices.assign(embedding, seconds: Double(samples.count) / 16_000)
        clusters[track] = voices
        var names: [String: String] = [:]
        for voices in clusters.values {
            names.merge(LiveVoiceMatch.names(for: voices.voices, known: known)) { first, _ in first }
        }
        return Assignment(speakerID: id, knownNames: names)
    }

    private func embed(_ samples: [Float]) async -> [Float]? {
        do {
            if manager == nil {
                let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
                try await manager.prepareModels()
                self.manager = manager
            }
            guard let manager else { return nil }
            let source = ArrayAudioSampleSource(samples: samples)
            let embeddings = try await manager.embedSpans(audioSource: source, spans: [0..<(Double(samples.count) / 16_000)])
            return embeddings.first
        } catch {
            print("[live] voice print failed: \(error)")
            // A model that does not load will not load on the next utterance either.
            if manager == nil { failed = true }
            return nil
        }
    }

    /// The known voices to name speakers by, when voice recognition is on.
    @MainActor
    static func knownVoices(in context: ModelContext) -> [LiveKnownVoice] {
        guard AppSettings.voiceRecognitionEnabled else { return [] }
        let profiles = (try? context.fetch(FetchDescriptor<VoiceProfile>())) ?? []
        return profiles.map { LiveKnownVoice(id: $0.id.uuidString, name: $0.name, voice: $0.voice) }
    }
}

/// A known voice, read from `VoiceProfile`.
struct LiveKnownVoice: Sendable, Equatable {
    let id: String
    let name: String
    let voice: [Float]
}

/// How the voices of one track are named, in order of appearance.
enum LiveSpeakerIDs: Sendable, Equatable {
    /// A channel's voices: the first keeps the channel's id, the next ones are "<id>.2", "<id>.3"… (as
    /// `SpeakerAssigner.splitChannel` names them after recording).
    case channel(String)
    /// The voices of a single microphone: "s1", "s2"… (as `SpeakerAssigner.byDiarization` names them).
    case voices

    func id(at index: Int) -> String {
        switch self {
        case .channel(let base): index == 0 ? base : "\(base).\(index + 1)"
        case .voices: "s\(index + 1)"
        }
    }
}

/// The voices heard on one track during a meeting: each the normalized sum of its voice prints. A new print joins
/// the most similar voice when it is at least `sameSpeaker` similar, else it starts a new one. Ids stay the same for
/// the whole meeting.
struct LiveVoiceClusters: Sendable {
    /// Cosine similarity at which a voice print is the same voice.
    static let sameSpeaker: Float = 0.7
    /// More voices than this on one track are not told apart: a print then joins the most similar voice.
    static let maximumVoices = 8

    struct Voice: Sendable, Equatable {
        let id: String
        var sum: [Float]
        var centroid: [Float]
        var seconds: Double
    }

    let scheme: LiveSpeakerIDs
    private(set) var voices: [Voice] = []

    init(scheme: LiveSpeakerIDs) {
        self.scheme = scheme
    }

    /// The id of the voice `embedding` belongs to (`seconds`: the speech behind it).
    mutating func assign(_ embedding: [Float], seconds: Double) -> String {
        let print = VoiceMath.normalized(embedding)
        let scored = voices.indices.map { (index: $0, score: VoiceMath.cosine(print, voices[$0].centroid)) }
        if let best = scored.max(by: { $0.score < $1.score }),
           best.score >= Self.sameSpeaker || voices.count >= Self.maximumVoices {
            var voice = voices[best.index]
            if voice.sum.count == print.count {
                voice.sum = zip(voice.sum, print).map(+)
                voice.centroid = VoiceMath.normalized(voice.sum)
            }
            voice.seconds += seconds
            voices[best.index] = voice
            return voice.id
        }
        let id = scheme.id(at: voices.count)
        voices.append(Voice(id: id, sum: print, centroid: print, seconds: seconds))
        return id
    }
}

/// Names live voices after known voices, with the thresholds of `VoiceProfiles.match`: similar enough, clearly
/// better than the next known voice, enough speech heard, and each person only once.
enum LiveVoiceMatch {
    /// `VoiceProfiles.matchThreshold`.
    static let threshold: Float = 0.60
    /// `VoiceProfiles.margin`.
    static let margin: Float = 0.06
    /// `VoiceProfiles.minSeconds`.
    static let minimumSeconds = 4.0

    /// Voice id → the known voice's name.
    static func names(for voices: [LiveVoiceClusters.Voice], known: [LiveKnownVoice]) -> [String: String] {
        guard !known.isEmpty else { return [:] }
        struct Candidate { let voice: String; let known: LiveKnownVoice; let score: Float }
        var candidates: [Candidate] = []
        for voice in voices where voice.seconds >= minimumSeconds {
            let scored = known
                .map { (known: $0, score: VoiceMath.cosine(voice.centroid, $0.voice)) }
                .sorted { $0.score > $1.score }
            guard let best = scored.first else { continue }
            let runnerUp = scored.count > 1 ? scored[1].score : -1
            guard best.score >= threshold, best.score - runnerUp >= margin else { continue }
            candidates.append(Candidate(voice: voice.id, known: best.known, score: best.score))
        }
        var taken = Set<String>()
        var names: [String: String] = [:]
        for candidate in candidates.sorted(by: { $0.score > $1.score }) where !taken.contains(candidate.known.id) {
            taken.insert(candidate.known.id)
            names[candidate.voice] = candidate.known.name
        }
        return names
    }
}
