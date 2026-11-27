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

    /// Seconds of speech closer than this count as the same (sums of word lengths are not exact).
    static let majorityTolerance = 0.005

    /// Each phrase goes to the voice with most of its speech; a tie (within `majorityTolerance`) leaves the words as
    /// they are.
    static func majorityByPhrase(_ ids: [String], words: [Word], among: Set<Int>) -> [String] {
        var out = ids
        for phrase in phrases(words, among: among) where phrase.count > 1 {
            var seconds: [String: Double] = [:]
            for index in phrase { seconds[ids[index], default: 0] += max(0.01, words[index].end - words[index].start) }
            let ranked = seconds.sorted { $0.value > $1.value }
            guard let best = ranked.first, ranked.count > 1, best.value - ranked[1].value > majorityTolerance else { continue }
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
    /// How far (seconds) the start, or the end, of a left word may be from the right word it repeats.
    static let echoWindow = 0.5
    /// The loudspeaker reaches the microphone a little later, and the two recognizers place a word a little apart:
    /// the right channel's level is also taken up to this many seconds earlier than the left word.
    static let echoDelay = 0.2
    /// A lone left word or two (no other left word within `phrasePause`), at most this long, that lies within a
    /// phrase of the right channel and is said there too, is that phrase's echo (with the right channel louder).
    static let echoIslandSeconds = 0.8
    static let echoIslandWords = 2

    /// Drops the left words that are only the others' voices from the loudspeaker, picked up again by the user's
    /// microphone, or made up by the recognizer on its noise or silence: first every word without the user's own
    /// voice in its time by the levels alone (`MicrophoneVoice`); then, of the rest that do not carry the user's
    /// voice through most of their time (`MicrophoneVoice.isMostlyOwn`), those where the right channel is clearly
    /// louder in the word's time (by its typical level, or plainly; the right side also taken up to `echoDelay`
    /// earlier) and a right word reads the same and starts or ends within `echoWindow` of it, or the word is a
    /// lone short piece inside a right phrase that says it (`echoIslandSeconds`). Short words count only when equal
    /// (`sameWord`). When in doubt a word is kept: a "Yes." of the user that the others did not say stays, and so
    /// does anything louder on the microphone.
    static func droppingEcho(left: [Word], right: [Word], energy: ChannelEnergy) -> [Word] {
        let count = min(energy.left.count, energy.right.count)
        guard count > 0 else { return left }
        // Without the user's own voice in its time a word is the others' echo, noise or silence, whatever the
        // others' recognizer made of that moment (`MicrophoneVoice`).
        let voice = MicrophoneVoice(energy)
        let left = left.filter { voice.mayBeUser(from: $0.start, to: $0.end) }
        guard !right.isEmpty else { return left }
        let leftRef = percentile(energy.left, 0.9)
        let rightRef = percentile(energy.right, 0.9)
        let eps: Float = 1e-10
        let shifts = max(0, Int((echoDelay / energy.frameDuration).rounded()))

        func frames(_ start: Double, _ end: Double) -> ClosedRange<Int> {
            let a = min(count - 1, max(0, Int(start / energy.frameDuration)))
            let b = min(count - 1, max(a, Int((end / energy.frameDuration).rounded(.up))))
            return a...b
        }
        /// The right channel clearly louder than the left between two times.
        func louderOnRight(_ start: Double, _ end: Double) -> Bool {
            let range = frames(start, end)
            let l = range.reduce(Float(0)) { $0 + energy.left[$1] }
            for shift in 0...shifts {
                var r: Float = 0
                for i in range { r += energy.right[max(0, i - shift)] }
                let normalized = 10 * log10((r / max(rightRef, eps) + eps) / (l / max(leftRef, eps) + eps))
                let plain = 10 * log10((r + eps) / (l + eps))
                if normalized > echoMarginDB || plain > echoMarginDB { return true }
            }
            return false
        }

        let sortedRight = right.sorted { $0.start < $1.start }
        var dropped = Set<Int>()
        // The user's voice through most of a word: theirs, even when the others say the same at that time.
        let own = left.map { voice.isMostlyOwn(from: $0.start, to: $0.end) }
        for (index, word) in left.enumerated() where !own[index] && louderOnRight(word.start, word.end) {
            let repeated = sortedRight.contains {
                (abs($0.start - word.start) <= echoWindow || abs($0.end - word.end) <= echoWindow) && sameWord($0.text, word.text)
            }
            if repeated { dropped.insert(index) }
        }

        // Lone short pieces inside a phrase of the others that says them.
        let rightPhrases = phrases(sortedRight, among: Set(sortedRight.indices)).map { phrase in
            (start: sortedRight[phrase[0]].start, end: sortedRight[phrase[phrase.count - 1]].end, words: phrase.map { sortedRight[$0].text })
        }
        for island in echoIslands(left) where island.contains(where: { !dropped.contains($0) }) {
            let start = left[island[0]].start
            let end = left[island[island.count - 1]].end
            let inside = rightPhrases.contains { phrase in
                start >= phrase.start - 0.1 && end <= phrase.end + 0.3
                    && island.allSatisfy { index in phrase.words.contains { sameWord($0, left[index].text) } }
            }
            if inside, !island.contains(where: { own[$0] }), louderOnRight(start, end) { dropped.formUnion(island) }
        }
        return left.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
    }

    /// Runs of at most `echoIslandWords` left words, together at most `echoIslandSeconds` long, with no other left
    /// word within `phrasePause` before or after.
    static func echoIslands(_ words: [Word]) -> [[Int]] {
        var runs: [[Int]] = []
        for index in words.indices {
            if let last = runs.last?.last, words[index].start - words[last].end < phrasePause {
                runs[runs.count - 1].append(index)
            } else {
                runs.append([index])
            }
        }
        return runs.filter { run in
            run.count <= echoIslandWords && words[run[run.count - 1]].end - words[run[0]].start <= echoIslandSeconds
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

/// Whether the user's microphone carries a voice of its own, from the levels of both sides of a Mac call alone
/// (the microphone and the Mac's sound), whatever was recognized there. The microphone hears the others from the
/// loudspeaker only as a delayed, quieter, reverberant copy of the Mac's sound: at each moment at most about the
/// Mac's loudest level of the last `reachSeconds` times the room's coupling (`gain`). A frame is the user's own
/// voice when the microphone is clearly above both that echo and its own quiet; a stretch without such frames is
/// only the others' echo, room noise or silence, and words recognized there are no words of the user (the
/// recognizer also makes up words on silence and noise). Used after recording (`SpeakerAssigner.droppingEcho`,
/// 50 ms frames) and live (`LiveEcho`, 100 ms frames).
struct MicrophoneVoice: Sendable {
    /// The loudspeaker's delay to the microphone plus the room's reverberation that still matters: the echo at a
    /// moment comes from the Mac's sound of up to this many seconds before (a delay of 0.1–0.2 s, a tail of
    /// ~0.2 s that has fallen by well over 10 dB in a room with a reverberation time of 0.5 s).
    static let reachSeconds = 0.4
    /// The microphone must be this much (dB) above the echo predicted for the frame. The prediction uses the Mac's
    /// loudest level within `reachSeconds` and the median coupling, so a pure echo stays below it by a few dB; the
    /// user's own voice is 15–30 dB above the echo of a loudspeaker in a normal room.
    static let echoMarginDB: Float = 6
    /// And this much (dB) above the microphone's quiet (its 10th percentile): stationary room noise varies by
    /// 1–3 dB per frame, speech is 20 dB and more above it.
    static let quietMarginDB: Float = 10
    /// The quiet is taken no louder than this (power, -50 dBFS), so a stretch the user talks through from the
    /// first second (live, where little is measured) never counts as quiet.
    static let loudestQuiet: Float = 1e-5
    /// Below this (power, -70 dBFS) a frame is silence however the rest measures.
    static let silence: Float = 1e-7
    /// The coupling is measured where the Mac's sound is loud: at most this many dB below its typical loud level
    /// (90th percentile), so room noise during the Mac's quiet moments does not count as echo.
    static let loudSystemBelowTypicalDB: Float = 10
    /// The coupling is the median of microphone / Mac over those frames: up to half of them may be the user
    /// talking over the others before it is taken too high.
    static let gainPercentile = 0.5
    /// The coupling is measured for blocks of this many seconds from the frames within `gainSpanSeconds` around
    /// them (the loudspeaker's volume may change during a meeting); with under `minimumGainFrames` loud frames
    /// there, the whole recording's.
    static let gainBlockSeconds = 30.0
    static let gainSpanSeconds = 60.0
    static let minimumGainFrames = 20
    /// A word or utterance is the user's when its time, widened by `pad` on both sides (the recognizers' timing),
    /// holds at least this many seconds of the user's own voice (two 50 ms frames, one 100 ms frame live).
    static let minimumSeconds = 0.1
    static let pad = 0.2

    let frameDuration: Double
    /// Microphone power per frame.
    private let microphone: [Float]
    /// The Mac's loudest power within `reachSeconds` up to each frame.
    private let reach: [Float]
    private let quiet: Float
    private let gains: [Float]
    private let blockFrames: Int

    /// `microphone` and `system`: mean square power per frame of `frameDuration` seconds, from the same start.
    init(frameDuration: Double, microphone: [Float], system: [Float]) {
        let count = min(microphone.count, system.count)
        self.frameDuration = frameDuration
        self.microphone = Array(microphone.prefix(count))
        let system = Array(system.prefix(count))
        let back = max(0, Int((Self.reachSeconds / frameDuration).rounded()))
        var reach = [Float](repeating: 0, count: count)
        for i in 0..<count {
            var loudest: Float = 0
            for k in max(0, i - back)...i { loudest = max(loudest, system[k]) }
            reach[i] = loudest
        }
        self.reach = reach
        quiet = min(Self.percentile(self.microphone, 0.1), Self.loudestQuiet)

        // The room's coupling from the Mac's loud frames.
        let typical = Self.percentile(system, 0.9)
        let loud = max(typical / pow(10, Self.loudSystemBelowTypicalDB / 10), Self.silence * 10)
        let mic = self.microphone
        func ratios(_ range: Range<Int>) -> [Float] {
            range.compactMap { i in system[i] >= loud ? mic[i] / max(reach[i], 1e-12) : nil }
        }
        let all = ratios(0..<count)
        let global = all.isEmpty ? 0 : Self.percentile(all, Self.gainPercentile)
        blockFrames = max(1, Int((Self.gainBlockSeconds / frameDuration).rounded()))
        let span = Int((Self.gainSpanSeconds / frameDuration).rounded())
        var gains: [Float] = []
        var start = 0
        while start < count {
            let range = max(0, start - span)..<min(count, start + blockFrames + span)
            let local = ratios(range)
            gains.append(local.count >= Self.minimumGainFrames ? Self.percentile(local, Self.gainPercentile) : global)
            start += blockFrames
        }
        self.gains = gains
    }

    init(_ energy: ChannelEnergy) {
        self.init(frameDuration: energy.frameDuration, microphone: energy.left, system: energy.right)
    }

    /// Whether the microphone carries the user's own voice in a frame.
    func isOwn(_ i: Int) -> Bool {
        let echo = gains[min(gains.count - 1, i / blockFrames)] * reach[i]
        let level = microphone[i]
        return level >= Self.silence
            && level > quiet * pow(10, Self.quietMarginDB / 10)
            && level > echo * pow(10, Self.echoMarginDB / 10)
    }

    /// Seconds of the user's own voice between two times; nil when nothing was measured there.
    func ownSeconds(from start: Double, to end: Double) -> Double? {
        let a = max(0, Int(start / frameDuration))
        let b = min(microphone.count, Int((end / frameDuration).rounded(.up)))
        guard b > a else { return nil }
        return Double((a..<b).filter(isOwn).count) * frameDuration
    }

    /// The user's own voice fills at least this share of a word's time (not widened): the word is theirs even when
    /// the others say the same then (the text rules of `SpeakerAssigner.droppingEcho` leave it alone).
    static let mostlyOwnShare = 0.5

    /// Whether the user's own voice fills at least `mostlyOwnShare` of the frames between two times.
    func isMostlyOwn(from start: Double, to end: Double) -> Bool {
        let a = max(0, Int(start / frameDuration))
        let b = min(microphone.count, Int((end / frameDuration).rounded(.up)))
        guard b > a else { return false }
        return Double((a..<b).filter(isOwn).count) >= Self.mostlyOwnShare * Double(b - a)
    }

    /// Whether a word or utterance between two times may be the user's: it holds `minimumSeconds` of their own
    /// voice (its time widened by `pad`), or nothing was measured there (in doubt it is kept).
    func mayBeUser(from start: Double, to end: Double) -> Bool {
        guard let seconds = ownSeconds(from: start - Self.pad, to: end + Self.pad) else { return true }
        return seconds >= Self.minimumSeconds - 1e-9
    }

    private static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
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
