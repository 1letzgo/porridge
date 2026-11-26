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
    /// one voice) go to the kept voice whose print is most like theirs (`voices`, by diarization label), or stay with
    /// the voice before them when there are no prints. Within a phrase (`phrases`) the voice with most of its speech
    /// wins, so single words do not flicker between voices. Other words are untouched; one voice changes nothing.
    static func splitChannel(
        _ words: [Word], ids: [String?], channel: String, segments: [DiarizedSegment],
        voices: [String: [Float]] = [:], minimumSeconds: Double = 8
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

        // Too little speech for a person of its own: the kept voice that sounds most alike, when prints are there.
        let kept = Array(mapping.keys)
        for label in Set(raw.values) where mapping[label] == nil {
            guard let print = voices[label] else { continue }
            let best = kept.compactMap { other in voices[other].map { (other, VoiceMath.cosine(print, $0)) } }
                .max { $0.1 < $1.1 }
            if let best { mapping[label] = mapping[best.0] }
        }

        var split = ids.map { $0 ?? "" }
        var previous = channel
        for index in onChannel {
            let id = raw[index].flatMap { mapping[$0] } ?? previous
            split[index] = id
            previous = id
        }
        split = majorityByPhrase(split, words: words, among: Set(onChannel))
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

    // MARK: - Phrases

    /// A phrase ends at a pause of this many seconds or more.
    static let phrasePause = 0.5
    /// A phrase without pause or sentence end is cut after this many seconds, so a long stretch is never one decision.
    static let phraseMaxSeconds = 8.0

    /// The runs of consecutive indices in `among` that belong together: no pause of `phrasePause`, no sentence end,
    /// not longer than `phraseMaxSeconds`, no word of another channel in between.
    static func phrases(_ words: [Word], among: Set<Int>) -> [[Int]] {
        var result: [[Int]] = []
        var current: [Int] = []
        for index in words.indices {
            guard among.contains(index) else {
                if !current.isEmpty { result.append(current); current = [] }
                continue
            }
            if let last = current.last, let first = current.first {
                let pause = words[index].start - words[last].end
                if index != last + 1 || pause >= phrasePause || endsSentence(words[last].text)
                    || words[index].end - words[first].start > phraseMaxSeconds {
                    result.append(current)
                    current = []
                }
            }
            current.append(index)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Each phrase goes to the voice with most of its speech; a tie leaves the words as they are.
    static func majorityByPhrase(_ ids: [String], words: [Word], among: Set<Int>) -> [String] {
        var out = ids
        for phrase in phrases(words, among: among) where phrase.count > 1 {
            var seconds: [String: Double] = [:]
            for index in phrase { seconds[ids[index], default: 0] += max(0.01, words[index].end - words[index].start) }
            let ranked = seconds.sorted { $0.value > $1.value }
            guard let best = ranked.first, ranked.count > 1, best.value > ranked[1].value else { continue }
            for index in phrase { out[index] = best.key }
        }
        return out
    }

    // MARK: - Each channel on its own (the Mac's meetings)

    /// The words of the left channel (the user's microphone) and of the right one (the Mac's sound), recognized each
    /// on its own, as one stream in time order: left words are `leftChannelID`, right ones `rightChannelID`. Each
    /// channel's words stay together per phrase (`phrases`), so talking at the same time does not interleave word by
    /// word; phrases are ordered by their start (the left first at the same time).
    static func mergeChannels(left: [Word], right: [Word]) -> (words: [Word], ids: [String]) {
        struct Run { let start: Double; let channel: Int; let words: [Word] }
        func runs(_ words: [Word], channel: Int) -> [Run] {
            phrases(words, among: Set(words.indices)).map { phrase in
                Run(start: words[phrase[0]].start, channel: channel, words: phrase.map { words[$0] })
            }
        }
        let ordered = (runs(left, channel: 0) + runs(right, channel: 1))
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.channel < $1.channel }
        var words: [Word] = []
        var ids: [String] = []
        for run in ordered {
            words += run.words
            ids += Array(repeating: run.channel == 0 ? leftChannelID : rightChannelID, count: run.words.count)
        }
        return (words, ids)
    }

    /// How much louder (dB) the right channel must be in a left word's time for it to count as the speakers'
    /// sound picked up by the microphone.
    static let echoMarginDB: Float = 6
    /// How far (seconds) the start of a left word may be from the right word it repeats.
    static let echoWindow = 0.5

    /// Drops the left words that are only the others' voices from the loudspeaker, picked up again by the user's
    /// microphone: the right channel is clearly louder in the word's time (by its typical level, or plainly) and a
    /// right word starting within `echoWindow` reads the same. When in doubt a word is kept.
    static func droppingEcho(left: [Word], right: [Word], energy: ChannelEnergy) -> [Word] {
        let count = min(energy.left.count, energy.right.count)
        guard count > 0, !right.isEmpty else { return left }
        let leftRef = percentile(energy.left, 0.9)
        let rightRef = percentile(energy.right, 0.9)
        let eps: Float = 1e-10
        let sortedRight = right.sorted { $0.start < $1.start }
        return left.filter { word in
            let a = min(count - 1, max(0, Int(word.start / energy.frameDuration)))
            let b = min(count - 1, max(a, Int((word.end / energy.frameDuration).rounded(.up))))
            var l: Float = 0
            var r: Float = 0
            for i in a...b {
                l += energy.left[i]
                r += energy.right[i]
            }
            let normalized = 10 * log10((r / max(rightRef, eps) + eps) / (l / max(leftRef, eps) + eps))
            let plain = 10 * log10((r + eps) / (l + eps))
            guard normalized > echoMarginDB || plain > echoMarginDB else { return true }
            let repeated = sortedRight.contains { abs($0.start - word.start) <= echoWindow && sameWord($0.text, word.text) }
            return !repeated
        }
    }

    /// Whether two recognized words read the same: equal without case and punctuation, or (from four letters on)
    /// at most one letter apart.
    static func sameWord(_ a: String, _ b: String) -> Bool {
        let x = Array(a.lowercased().filter { $0.isLetter || $0.isNumber })
        let y = Array(b.lowercased().filter { $0.isLetter || $0.isNumber })
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        guard min(x.count, y.count) >= 4, abs(x.count - y.count) <= 1 else { return false }
        // Edit distance of at most one.
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[y.count] <= 1
    }

    /// The most voices speaker detection may find, from the people invited to the meeting (the user not among
    /// them, as `CalendarAccess` lists them): on the right channel of a Mac meeting only the others speak, so as
    /// many as were invited; on one channel with everybody, the invited, the user and one more who was not invited.
    /// nil without invited people: no limit.
    static func maxSpeakers(invited: Int, othersOnly: Bool) -> Int? {
        guard invited > 0 else { return nil }
        return othersOnly ? invited : invited + 2
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

/// Speakers of one meeting that turn out to be one person become one.
enum SpeakerMerge {
    /// Voice print similarity (cosine) from which two unnamed speakers of the same meeting and channel are taken for
    /// one person split in two by speaker detection. Well above `VoiceProfiles.matchThreshold` (0.60, across
    /// meetings and microphones): within one recording the same voice measures much closer, two people rarely do.
    static let sameVoiceThreshold: Float = 0.80

    /// Speakers told apart on the same source: the channel ("ch1.2" belongs to "ch1"), or speaker detection of one
    /// channel ("s1", "s2"). Speakers of different microphones are never merged by their voice.
    static func source(of id: String) -> String {
        if id.hasPrefix("ch") { return String(id.prefix { $0 != "." }) }
        return id.hasPrefix("s") ? "s" : id
    }

    /// After speaker detection and voice recognition: unnamed speakers (`VoiceProfiles.isUnnamed`) of the same
    /// source whose voices measure at least `sameVoiceThreshold` alike become the one that spoke first in the list.
    @MainActor
    static func mergingSameVoices(_ speakers: [Speaker], segments: [TranscriptSegment]) -> (speakers: [Speaker], segments: [TranscriptSegment]) {
        var speakers = speakers
        var segments = segments
        var merged = true
        while merged {
            merged = false
            search: for i in speakers.indices where VoiceProfiles.isUnnamed(speakers[i]) {
                guard let a = speakers[i].voice else { continue }
                for j in speakers.indices where j > i && VoiceProfiles.isUnnamed(speakers[j])
                    && source(of: speakers[i].id) == source(of: speakers[j].id) {
                    guard let b = speakers[j].voice,
                          VoiceMath.cosine(VoiceMath.floats(from: a), VoiceMath.floats(from: b)) >= sameVoiceThreshold else { continue }
                    (speakers, segments) = merging(speakers[j].id, into: speakers[i].id, speakers: speakers, segments: segments)
                    merged = true
                    break search
                }
            }
        }
        return (speakers, segments)
    }

    /// `absorbed`'s segments go to `kept`, and `absorbed` is removed. `kept` keeps its id, name and color; it takes
    /// over `absorbed`'s person when it had none, and both voice prints weighted by their seconds. Segments of the
    /// same speaker that now follow each other closely are joined.
    static func merging(_ absorbed: String, into kept: String, speakers: [Speaker], segments: [TranscriptSegment]) -> (speakers: [Speaker], segments: [TranscriptSegment]) {
        guard absorbed != kept, let from = speakers.first(where: { $0.id == absorbed }),
              let index = speakers.firstIndex(where: { $0.id == kept }) else { return (speakers, segments) }
        var result = speakers
        var target = result[index]
        if target.profileID == nil { target.profileID = from.profileID }
        switch (target.voice, from.voice) {
        case let (a?, b?):
            let wa = target.voiceSeconds ?? 0, wb = from.voiceSeconds ?? 0
            target.voice = VoiceMath.data(from: VoiceMath.blend(VoiceMath.floats(from: a), weight: wa, VoiceMath.floats(from: b), weight: wb))
            target.voiceSeconds = wa + wb
        case (nil, let b?):
            target.voice = b
            target.voiceSeconds = from.voiceSeconds
        default:
            break
        }
        result[index] = target
        result.removeAll { $0.id == absorbed }

        var joined: [TranscriptSegment] = []
        for var segment in segments.sorted(by: { $0.start < $1.start }) {
            if segment.speakerId == absorbed { segment.speakerId = kept }
            if var last = joined.last, last.speakerId == segment.speakerId, segment.speakerId == kept,
               segment.start - last.end < 2.0, segment.end - last.start <= 60 {
                last.text += " " + segment.text
                last.end = max(last.end, segment.end)
                joined[joined.count - 1] = last
            } else {
                joined.append(segment)
            }
        }
        return (result, joined)
    }
}
