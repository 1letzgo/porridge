import Foundation

struct DiarizedSegment: Sendable {
    let speaker: String
    let start: Double
    let end: Double
}

enum SpeakerAssigner {
    static let leftChannelID = "ch0"
    static let rightChannelID = "ch1"

    /// Assigns each word to the louder microphone. Both channels are normalized by their
    /// typical speech level first, so different gain settings on the two transmitters don't
    /// bias the decision; crosstalk is always much quieter than the wearer's own voice.
    static func byChannel(_ words: [Word], energy: ChannelEnergy) -> [String] {
        let count = min(energy.left.count, energy.right.count)
        guard count > 0 else { return words.map { _ in leftChannelID } }
        let leftRef = percentile(energy.left, 0.9)
        let rightRef = percentile(energy.right, 0.9)
        let eps: Float = 1e-10

        var result: [String] = []
        var previous: String?
        for word in words {
            let a = min(count - 1, max(0, Int(word.start / energy.frameDuration)))
            let b = min(count - 1, max(a, Int((word.end / energy.frameDuration).rounded(.up))))
            var l: Float = 0
            var r: Float = 0
            for i in a...b {
                l += energy.left[i]
                r += energy.right[i]
            }
            let db = 10 * log10((l / max(leftRef, eps) + eps) / (r / max(rightRef, eps) + eps))
            let id: String
            if abs(db) < 2, let previous {
                id = previous
            } else {
                id = db >= 0 ? leftChannelID : rightChannelID
            }
            result.append(id)
            previous = id
        }
        return smoothIslands(result, words: words)
    }

    /// Maps diarization segments onto words. Returns stable ids ("s1", "s2", …) in order of appearance.
    static func byDiarization(_ words: [Word], segments: [DiarizedSegment]) -> (ids: [String?], speakers: [String]) {
        guard !segments.isEmpty else { return (words.map { _ in nil }, []) }
        var mapping: [String: String] = [:]
        var order: [String] = []

        let ids: [String?] = words.map { word in
            let mid = (word.start + word.end) / 2
            let match = segments.first { mid >= $0.start && mid <= $0.end }
                ?? segments.min { distance(mid, $0) < distance(mid, $1) }
            guard let raw = match?.speaker else { return nil }
            if let mapped = mapping[raw] { return mapped }
            let mapped = "s\(order.count + 1)"
            mapping[raw] = mapped
            order.append(mapped)
            return mapped
        }
        let smoothed = smoothIslands(ids.map { $0 ?? "" }, words: words).map { $0.isEmpty ? nil : $0 }
        return (smoothed, order)
    }

    /// Tells several voices apart on one channel (the others of a call recorded from the Mac's sound). The words of
    /// `channel` take their diarization speaker: the first voice keeps the channel's id, the next ones become
    /// "ch1.2", "ch1.3"… in order of appearance. Voices with less than `minimumSeconds` of speech (false splits of
    /// one voice) stay with the voice before them. Other words are untouched; one voice changes nothing.
    static func splitChannel(
        _ words: [Word], ids: [String?], channel: String, segments: [DiarizedSegment], minimumSeconds: Double = 8
    ) -> (ids: [String?], added: [String]) {
        guard !segments.isEmpty, ids.count == words.count else { return (ids, []) }
        let onChannel = ids.indices.filter { ids[$0] == channel }
        var raw: [Int: String] = [:]
        var seconds: [String: Double] = [:]
        for index in onChannel {
            let word = words[index]
            let mid = (word.start + word.end) / 2
            let match = segments.first { mid >= $0.start && mid <= $0.end }
                ?? segments.min { distance(mid, $0) < distance(mid, $1) }
            guard let label = match?.speaker else { continue }
            raw[index] = label
            seconds[label, default: 0] += max(0, word.end - word.start)
        }
        var mapping: [String: String] = [:]
        var added: [String] = []
        for index in onChannel {
            guard let label = raw[index], mapping[label] == nil, seconds[label, default: 0] >= minimumSeconds else { continue }
            let id = mapping.isEmpty ? channel : "\(channel).\(mapping.count + 1)"
            mapping[label] = id
            if id != channel { added.append(id) }
        }
        guard !added.isEmpty else { return (ids, []) }

        var split = ids.map { $0 ?? "" }
        var previous = channel
        for index in onChannel {
            let id = raw[index].flatMap { mapping[$0] } ?? previous
            split[index] = id
            previous = id
        }
        let smoothed = smoothIslands(split, words: words)
        var result = ids
        // Smoothing only moves words between this channel's voices, never to the other channel.
        for index in onChannel {
            let id = smoothed[index]
            result[index] = id == channel || id.hasPrefix("\(channel).") ? id : split[index]
        }
        // A voice smoothed away entirely is not listed.
        let used = Set(onChannel.compactMap { result[$0] })
        return (result, added.filter(used.contains))
    }

    /// Groups consecutive words of the same speaker into readable segments.
    static func group(_ words: [Word], speakerIds: [String?]) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: TranscriptSegment?

        for (index, word) in words.enumerated() {
            let speaker = index < speakerIds.count ? speakerIds[index] : nil
            if var segment = current,
               segment.speakerId == speaker,
               word.start - segment.end < 2.0,
               !(segment.end - segment.start > 45 && endsSentence(segment.text)) {
                segment.text += " " + word.text
                segment.end = word.end
                current = segment
            } else {
                if let segment = current { segments.append(segment) }
                current = TranscriptSegment(speakerId: speaker, start: word.start, end: word.end, text: word.text)
            }
        }
        if let segment = current { segments.append(segment) }
        return segments
    }

    // MARK: - Helpers

    /// Flips single short words that interrupt the same speaker (A B A → A A A).
    private static func smoothIslands(_ ids: [String], words: [Word]) -> [String] {
        guard ids.count >= 3 else { return ids }
        var out = ids
        for i in 1..<(ids.count - 1)
        where ids[i - 1] == ids[i + 1] && ids[i] != ids[i - 1] && words[i].end - words[i].start < 0.6 {
            out[i] = ids[i - 1]
        }
        return out
    }

    private static func distance(_ t: Double, _ segment: DiarizedSegment) -> Double {
        t < segment.start ? segment.start - t : max(0, t - segment.end)
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".?!".contains(last)
    }

    private static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 1 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }
}
