import CoreGraphics
import Foundation

/// Which side of the transcript a bubble sits on: the user on the right, everybody else on the left.
enum BubbleSide: Equatable, Sendable {
    case leading
    case trailing
}

/// A speaker as a bubble shows it.
struct BubbleSpeaker: Equatable, Sendable {
    var id: String
    var name: String
    var colorIndex: Int
    var isMe: Bool
}

/// What was said by one speaker in a row, as one chat bubble. Its parts keep what is confirmed apart from what the
/// live recognizer may still change (shown dimmed).
struct TranscriptBubble: Identifiable, Equatable {
    struct Part: Identifiable, Equatable {
        let id: UUID
        var text: String
        var isFinal: Bool
    }

    /// The first part's id: stays while the bubble grows.
    let id: UUID
    var speakerID: String?
    var speaker: BubbleSpeaker?
    /// The speaker's name is shown above the bubble: the first bubble and every change of speaker.
    var showsName: Bool
    var side: BubbleSide
    var parts: [Part]
    var start: Double

    var text: String { parts.map(\.text).joined(separator: " ") }
    var isFinal: Bool { parts.allSatisfy(\.isFinal) }
}

/// The transcript as chat bubbles, live (`LiveTranscriber`) and after recording (the transcript's rows on Mac and
/// iPhone): "Me" on the right, every other speaker on the left, the name only where the speaker changes. When nobody
/// is "Me" (an imported recording, a single microphone) everything is on the left.
enum TranscriptBubbles {
    /// Bubbles are at most this share of the transcript's width.
    static let maximumWidth: CGFloat = 0.8
    /// Live: a speaker's utterances further apart than this start a new bubble (no new name).
    static let groupingGap = 20.0

    struct Item: Equatable {
        var id: UUID
        var speakerID: String?
        var text: String
        var isFinal: Bool
        var start: Double
        var end: Double
        /// False: the speaker is only taken from a neighbour (`LiveShortUtterances`), not measured.
        var speakerIsSure = true

        /// An open piece without a sure speaker is shown as nobody's yet: a neutral bubble of its own.
        var isNeutral: Bool { !isFinal && !speakerIsSure }
    }

    static func side(isMe: Bool) -> BubbleSide {
        isMe ? .trailing : .leading
    }

    /// Consecutive items of one speaker become one bubble; `speakers` by id (items without one: no name, left).
    /// An open piece whose speaker is only a guess (`Item.isNeutral`, a track with several voices) is not hung onto
    /// the bubble before it: it stands as a bubble of its own without a name, on the left (such tracks are the
    /// others' or a single microphone's), until its voice is measured.
    static func bubbles(_ items: [Item], speakers: [String: BubbleSpeaker]) -> [TranscriptBubble] {
        var result: [TranscriptBubble] = []
        var lastEnd = -Double.infinity
        for var item in items where !item.text.isEmpty {
            if item.isNeutral { item.speakerID = nil }
            let part = TranscriptBubble.Part(id: item.id, text: item.text, isFinal: item.isFinal)
            if var last = result.last, last.speakerID == item.speakerID, item.start - lastEnd <= groupingGap {
                last.parts.append(part)
                result[result.count - 1] = last
            } else {
                let speaker = item.speakerID.flatMap { speakers[$0] }
                result.append(TranscriptBubble(
                    id: item.id,
                    speakerID: item.speakerID,
                    speaker: speaker,
                    showsName: speaker != nil && result.last?.speakerID != item.speakerID,
                    side: side(isMe: speaker?.isMe ?? false),
                    parts: [part],
                    start: item.start
                ))
            }
            lastEnd = max(lastEnd, item.end)
        }
        return result
    }

    /// One row of a finished transcript (one segment each, so playing, jumping and reassigning stay per segment).
    struct RowStyle: Equatable {
        var side: BubbleSide
        /// The speaker's name above it: the first row and every change of speaker.
        var showsName: Bool
    }

    static func rows(speakerIDs: [String?], meIDs: Set<String>) -> [RowStyle] {
        speakerIDs.enumerated().map { index, id in
            RowStyle(
                side: side(isMe: id.map(meIDs.contains) ?? false),
                showsName: id != nil && (index == 0 || speakerIDs[index - 1] != id)
            )
        }
    }

    /// The speakers of a transcript that are the user: the voice marked as the user's, a name of the user, or a
    /// speaker literally called "Me" (the microphone's default name when recording a call on the Mac).
    @MainActor
    static func meIDs(in speakers: [Speaker]) -> Set<String> {
        Set(speakers.filter { AppSettings.isMe($0) || $0.name.caseInsensitiveCompare("Me") == .orderedSame }.map(\.id))
    }

    /// How a live speaker is shown. "ch0" is the microphone of a call on the Mac (the user, `meName`); "ch1" the Mac's
    /// sound (`othersName`, "Speaker 2" once more voices are heard there), "ch1.2"… its further voices; "s1"… the
    /// voices of a single microphone (on the right when recognized as the user's voice, `userIDs`). A known voice gives its name, except the user's on the Mac's sound. Names and colors are those the speakers get
    /// after recording (`ProcessingService`).
    static func liveSpeaker(
        id: String,
        allIDs: Set<String>,
        knownNames: [String: String],
        meName: String,
        othersName: String,
        isMeName: (String) -> Bool,
        userIDs: Set<String> = []
    ) -> BubbleSpeaker {
        let left = SpeakerAssigner.leftChannelID
        let right = SpeakerAssigner.rightChannelID
        let known = knownNames[id]
        if id == left {
            return BubbleSpeaker(id: id, name: known ?? meName, colorIndex: 0, isMe: true)
        }
        // The Mac's sound is the others: never the user, not even by a known voice's name.
        let isOthers = id == right || id.hasPrefix(right + ".")
        let other = isOthers && known.map { isMeName($0) || $0.caseInsensitiveCompare("Me") == .orderedSame } == true ? nil : known
        if id == right {
            let split = allIDs.contains { $0.hasPrefix(right + ".") }
            return BubbleSpeaker(id: id, name: other ?? (split ? "Speaker 2" : othersName), colorIndex: 1, isMe: false)
        }
        if id.hasPrefix(right + "."), let number = Int(id.dropFirst(right.count + 1)) {
            return BubbleSpeaker(id: id, name: other ?? "Speaker \(number + 1)", colorIndex: number, isMe: false)
        }
        if id.hasPrefix("s"), let number = Int(id.dropFirst()) {
            // One microphone has no fixed "Me": a voice recognized as the user's (`LiveKnownVoice.isUser`) is.
            let isMe = userIDs.contains(id) || (known.map(isMeName) ?? false)
            return BubbleSpeaker(id: id, name: known ?? "Speaker \(number)", colorIndex: max(0, number - 1), isMe: isMe)
        }
        return BubbleSpeaker(id: id, name: known ?? id, colorIndex: 0, isMe: false)
    }
}
