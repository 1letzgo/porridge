import Accelerate
import Foundation
import SwiftData

enum VoiceMath {
    static func normalized(_ v: [Float]) -> [Float] {
        var sum: Float = 0
        vDSP_svesq(v, 1, &sum, vDSP_Length(v.count))
        let norm = sum.squareRoot()
        guard norm > 0 else { return v }
        var scale = 1 / norm
        var out = [Float](repeating: 0, count: v.count)
        vDSP_vsmul(v, 1, &scale, &out, 1, vDSP_Length(v.count))
        return out
    }

    /// Cosine similarity of two voice prints (1 = same direction).
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        var sa: Float = 0, sb: Float = 0
        vDSP_svesq(a, 1, &sa, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &sb, vDSP_Length(b.count))
        let denominator = sa.squareRoot() * sb.squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }

    /// Weighted average of two voice prints, normalized again.
    static func blend(_ a: [Float], weight wa: Double, _ b: [Float], weight wb: Double) -> [Float] {
        guard a.count == b.count else { return b }
        let total = max(wa + wb, 0.001)
        var out = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count {
            out[i] = Float((Double(a[i]) * wa + Double(b[i]) * wb) / total)
        }
        return normalized(out)
    }

    static func data(from v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func floats(from data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// Recognizes people across meetings by their voice.
///
/// A voice print is made for every speaker of a meeting. When the user names a speaker, the print becomes
/// (or refines) the person's profile; later meetings and older unnamed speakers are matched against the profiles.
@MainActor
enum VoiceProfiles {
    /// Cosine similarity needed to treat two voices as the same person.
    static let matchThreshold: Float = 0.60
    /// The best profile must beat the second best by this much.
    static let margin: Float = 0.06
    /// Matches this good also refine the profile.
    static let refineThreshold: Float = 0.72
    /// Speech needed from a speaker before a match is trusted.
    static let minSeconds = 4.0

    private static let defaultNamePrefix = "Speaker "

    // MARK: - New meeting

    /// Adds a voice print to every speaker and names those that match a known person.
    static func identify(
        _ speakers: [Speaker],
        segments: [TranscriptSegment],
        audio: URL,
        context: ModelContext
    ) async -> [Speaker] {
        guard !speakers.isEmpty else { return speakers }
        try? await ModelManager.shared.ensureDiarizer()

        var result = speakers
        for index in result.indices {
            guard let print = await fingerprint(of: result[index].id, in: segments, audio: audio) else { continue }
            result[index].voice = VoiceMath.data(from: print.voice)
            result[index].voiceSeconds = print.seconds
        }
        // Speakers that were named while recording (e.g. the two DJI microphones) teach their voices right away.
        for index in result.indices
        where result[index].profileID == nil && !result[index].name.hasPrefix(defaultNamePrefix) {
            teach(&result[index], context: context)
        }
        try? context.save()

        let profiles = (try? context.fetch(FetchDescriptor<VoiceProfile>())) ?? []
        return match(result, against: profiles, refine: true)
    }

    private static func fingerprint(of speakerID: String, in segments: [TranscriptSegment], audio: URL) async -> (voice: [Float], seconds: Double)? {
        // The longest stretches of this speaker's speech are the cleanest material.
        let turns = segments
            .filter { $0.speakerId == speakerID && $0.end - $0.start >= 1.5 }
            .sorted { $0.end - $0.start > $1.end - $1.start }
        var spans: [Range<Double>] = []
        var seconds = 0.0
        for turn in turns where spans.count < 8 && seconds < 60 {
            let length = min(turn.end - turn.start, 12)
            spans.append(turn.start..<(turn.start + length))
            seconds += length
        }
        guard seconds >= 3,
              let embeddings = try? await TranscriptionEngine.shared.embed(audio, spans: spans),
              !embeddings.isEmpty else { return nil }
        let normalized = embeddings.map(VoiceMath.normalized)
        let sum = normalized.dropFirst().reduce(normalized[0]) { zip($0, $1).map(+) }
        return (VoiceMath.normalized(sum), seconds)
    }

    // MARK: - Matching

    /// Names speakers that still carry their default name when a profile fits clearly.
    @discardableResult
    static func match(_ speakers: [Speaker], against profiles: [VoiceProfile], refine: Bool) -> [Speaker] {
        guard !profiles.isEmpty else { return speakers }
        var result = speakers

        struct Candidate { let speaker: Int; let profile: VoiceProfile; let score: Float; let runnerUp: Float }
        var candidates: [Candidate] = []
        for (index, speaker) in result.enumerated() {
            guard speaker.profileID == nil, speaker.name.hasPrefix(defaultNamePrefix),
                  let data = speaker.voice, (speaker.voiceSeconds ?? 0) >= minSeconds else { continue }
            let voice = VoiceMath.floats(from: data)
            let scored = profiles
                .map { (profile: $0, score: VoiceMath.cosine(voice, $0.voice)) }
                .sorted { $0.score > $1.score }
            guard let best = scored.first else { continue }
            let runnerUp = scored.count > 1 ? scored[1].score : -1
            print("[voice] \(speaker.name): best \(best.profile.name) \(String(format: "%.2f", best.score)), next \(String(format: "%.2f", runnerUp))")
            candidates.append(Candidate(speaker: index, profile: best.profile, score: best.score, runnerUp: runnerUp))
        }

        // Most certain matches first; one person only once per meeting.
        var taken = Set<UUID>()
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            guard candidate.score >= matchThreshold,
                  candidate.score - candidate.runnerUp >= margin,
                  !taken.contains(candidate.profile.id) else { continue }
            taken.insert(candidate.profile.id)
            result[candidate.speaker].name = candidate.profile.name
            result[candidate.speaker].profileID = candidate.profile.id.uuidString

            if refine, candidate.score >= refineThreshold,
               let data = result[candidate.speaker].voice {
                let seconds = result[candidate.speaker].voiceSeconds ?? 0
                absorb(VoiceMath.floats(from: data), seconds: seconds, into: candidate.profile)
            }
        }
        return result
    }

    private static func absorb(_ voice: [Float], seconds: Double, into profile: VoiceProfile) {
        profile.voice = VoiceMath.blend(profile.voice, weight: min(profile.seconds, 120), voice, weight: seconds)
        profile.seconds = min(profile.seconds + seconds, 300)
        profile.updatedAt = Date()
    }

    // MARK: - Naming

    /// Renames a speaker and learns the voice under that name. Call `rematchAllMeetings` after storing the result.
    static func rename(speakerID: String, to name: String, in speakers: [Speaker], context: ModelContext) -> [Speaker] {
        var result = speakers
        guard let index = result.firstIndex(where: { $0.id == speakerID }) else { return speakers }
        result[index].name = name

        if result[index].voice != nil {
            teach(&result[index], context: context)
            try? context.save()
        }
        return result
    }

    /// Stores the speaker's voice under the speaker's name: refines the person's profile or creates it.
    private static func teach(_ speaker: inout Speaker, context: ModelContext) {
        guard let data = speaker.voice else { return }
        let voice = VoiceMath.floats(from: data)
        let seconds = speaker.voiceSeconds ?? 0
        let profiles = (try? context.fetch(FetchDescriptor<VoiceProfile>())) ?? []
        if let profile = profiles.first(where: { $0.name.caseInsensitiveCompare(speaker.name) == .orderedSame }) {
            // Same person already known: only add this voice if it really is the profile's voice.
            if speaker.profileID == profile.id.uuidString || VoiceMath.cosine(voice, profile.voice) >= 0.45 {
                absorb(voice, seconds: seconds, into: profile)
            }
            speaker.profileID = profile.id.uuidString
        } else {
            let profile = VoiceProfile(name: speaker.name, voice: voice, seconds: seconds)
            context.insert(profile)
            speaker.profileID = profile.id.uuidString
        }
    }

    /// Names earlier speakers that still have their default name, using what is known now.
    static func rematchAllMeetings(context: ModelContext) {
        let profiles = (try? context.fetch(FetchDescriptor<VoiceProfile>())) ?? []
        guard !profiles.isEmpty else { return }
        for meeting in (try? context.fetch(FetchDescriptor<Note>())) ?? [] {
            let before = meeting.speakers
            let after = match(before, against: profiles, refine: false)
            if after != before { meeting.speakers = after }
        }
        try? context.save()
    }

    /// Renames a person everywhere.
    static func rename(_ profile: VoiceProfile, to name: String, context: ModelContext) {
        profile.name = name
        profile.updatedAt = Date()
        for meeting in (try? context.fetch(FetchDescriptor<Note>())) ?? [] {
            var speakers = meeting.speakers
            var changed = false
            for index in speakers.indices where speakers[index].profileID == profile.id.uuidString {
                speakers[index].name = name
                changed = true
            }
            if changed { meeting.speakers = speakers }
        }
        try? context.save()
    }

    /// Forgets a person's voice. Names already given in meetings stay.
    static func delete(_ profile: VoiceProfile, context: ModelContext) {
        for meeting in (try? context.fetch(FetchDescriptor<Note>())) ?? [] {
            var speakers = meeting.speakers
            var changed = false
            for index in speakers.indices where speakers[index].profileID == profile.id.uuidString {
                speakers[index].profileID = nil
                changed = true
            }
            if changed { meeting.speakers = speakers }
        }
        context.delete(profile)
        try? context.save()
    }
}
