import SwiftUI

/// One passage of a transcript as a chat bubble (`TranscriptBubbles`): on the user's side or the others', the
/// speaker (where it changes) and the time on top, the text below.
struct SegmentRow: View {
    let segment: TranscriptSegment
    let speaker: Speaker?
    let isActive: Bool
    var style = TranscriptBubbles.RowStyle(side: .leading, showsName: true)
    /// The menu a tap on the speaker's name opens (naming it, giving the line to another one); none: just the name.
    var speakerMenu: (() -> AnyView)?
    /// Plays the recording from this passage (a tap on the row outside the name); nil: nothing to play.
    var onPlay: (() -> Void)?

    private var trailing: Bool { style.side == .trailing }

    var body: some View {
        BubbleRowLayout(trailing: trailing) {
            VStack(alignment: trailing ? .trailing : .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let speaker, style.showsName {
                        if let speakerMenu {
                            Menu { speakerMenu() } label: { speakerName(speaker, isMenu: true) }
                                .menuStyle(.button)
                                .buttonStyle(.plain)
                                .accessibilityLabel("Speaker \(speaker.name)")
                                .accessibilityHint("Name the speaker")
                        } else {
                            speakerName(speaker, isMenu: false)
                        }
                    }
                    Text(segment.start.clockString)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(segment.text)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { onPlay?() }
                    .accessibilityLabel(speaker.map { "\($0.name): \(segment.text)" } ?? segment.text)
                    .accessibilityAddTraits(onPlay == nil ? [] : .isButton)
                    .accessibilityHint(onPlay == nil ? "" : "Plays the recording from here.")
                    .accessibilityAction { onPlay?() }
            }
            // Flat tint of the speaker's color (no shadow, which a scroll view would cut off at its edges).
            .padding(14)
            .background(
                isActive ? Color.brandSky.opacity(0.22) : (speaker.map { Color.speaker($0.colorIndex) } ?? .gray).opacity(0.1),
                in: RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous)
            )
        }
        // A new speaker gets a little more room above.
        .padding(.top, style.showsName ? 6 : 0)
    }

    private func speakerName(_ speaker: Speaker, isMenu: Bool) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color.speaker(speaker.colorIndex)).frame(width: 10, height: 10)
            Text(speaker.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.brandNavy)
            if AppSettings.isMe(speaker) { MeBadge() }
            // An unnamed speaker invites a name.
            if isMenu, VoiceProfiles.isUnnamed(speaker) {
                Text("Name…").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A chat bubble across the width it is given: the bubble takes at most `TranscriptBubbles.maximumWidth` of it, as
/// narrow as its content allows, on the leading or the trailing side.
struct BubbleRowLayout: Layout {
    var trailing: Bool
    var fraction = TranscriptBubbles.maximumWidth

    private func bubbleSize(_ subviews: Subviews, width: CGFloat?) -> CGSize {
        guard let bubble = subviews.first else { return .zero }
        return bubble.sizeThatFits(ProposedViewSize(width: width.map { $0 * fraction }, height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = bubbleSize(subviews, width: proposal.width)
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bubble = subviews.first else { return }
        let size = bubbleSize(subviews, width: bounds.width)
        let x = trailing ? bounds.maxX - size.width : bounds.minX
        bubble.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

/// Marks the user among the speakers.
struct MeBadge: View {
    var body: some View {
        Text("Me")
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.brandOnFill)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.brandTask, in: Capsule())
            .accessibilityLabel("You")
    }
}

struct PlayerBar: View {
    let player: AudioPlayback
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 14) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3.weight(.semibold))
                    .chunkyCircle(size: 48)
            }
            .buttonStyle(.plain)
            Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
            Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
            Slider(
                value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 1)
            )
            .tint(Color.brandNavy)
            Text(player.currentTime.clockString)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash").foregroundStyle(Color.brandDangerText)
                }
                .accessibilityLabel("Delete Recording")
            }
        }
        .font(.title3.weight(.semibold))
        .foregroundStyle(Color.brandNavy)
        .chunkyCard(padding: 12)
    }
}
