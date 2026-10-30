import SwiftUI

/// One passage of a transcript: speaker, time and text.
struct SegmentRow: View {
    let segment: TranscriptSegment
    let speaker: Speaker?
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let speaker {
                    Circle().fill(Color.speaker(speaker.colorIndex)).frame(width: 10, height: 10)
                    Text(speaker.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.brandNavy)
                    if AppSettings.isMe(speaker) { MeBadge() }
                }
                Spacer()
                Text(segment.start.clockString)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(segment.text)
                .textSelection(.enabled)
        }
        // Flat tint of the speaker's color (no shadow, which a scroll view would cut off at its edges).
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isActive ? Color.brandSky.opacity(0.22) : (speaker.map { Color.speaker($0.colorIndex) } ?? .gray).opacity(0.08),
            in: RoundedRectangle(cornerRadius: Look.cardRadius, style: .continuous)
        )
    }
}

/// Marks the user among the speakers.
struct MeBadge: View {
    var body: some View {
        Text("Me")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
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
                    Image(systemName: "trash").foregroundStyle(.red)
                }
                .accessibilityLabel("Delete Recording")
            }
        }
        .font(.title3.weight(.semibold))
        .foregroundStyle(Color.brandNavy)
        .chunkyCard(padding: 12)
    }
}
