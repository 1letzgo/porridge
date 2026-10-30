import Foundation

struct Speaker: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var colorIndex: Int
    /// Voice print of this speaker in this meeting (Float32 bytes) and the seconds of speech behind it.
    var voice: Data?
    var voiceSeconds: Double?
    /// The recognized or taught person (`VoiceProfile.id`).
    var profileID: String?
}

struct TranscriptSegment: Codable, Hashable, Identifiable {
    var id = UUID()
    var speakerId: String?
    var start: Double
    var end: Double
    var text: String
}

/// A recognized word with timing, independent of the ASR library.
struct Word: Hashable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

enum ProcessingStatus: String, Codable {
    case recorded
    case transcribing
    case ready
    case failed
}

enum SpeakerMode: String, Codable {
    /// No speaker separation.
    case none
    /// Each audio channel belongs to one speaker (e.g. DJI Mic in stereo mode).
    case channels
    /// Speakers detected from a single channel via diarization.
    case diarized
}

extension TimeInterval {
    var clockString: String {
        let total = Int(self.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    var durationText: String {
        let minutes = Int((self / 60).rounded())
        if self < 60 { return "\(Int(self)) sec" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
