import Foundation
import SwiftData

/// A person's voice, learned when a speaker is named. Only the voice print (a vector of numbers) is stored,
/// never audio. CloudKit-compatible: every property has a default.
@Model
final class VoiceProfile {
    var id: UUID = UUID()
    var name: String = ""
    /// L2-normalized voice print as Float32 bytes.
    var voiceData: Data = Data()
    /// Seconds of speech the voice print is based on.
    var seconds: Double = 0
    var updatedAt: Date = Date()

    init(name: String, voice: [Float], seconds: Double) {
        self.id = UUID()
        self.name = name
        self.voiceData = VoiceMath.data(from: voice)
        self.seconds = seconds
    }

    var voice: [Float] {
        get { VoiceMath.floats(from: voiceData) }
        set { voiceData = VoiceMath.data(from: newValue) }
    }
}
