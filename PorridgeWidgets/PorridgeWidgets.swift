import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct PorridgeWidgets: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
        QuickActionsWidget()
        NewNoteControl()
        StartMeetingControl()
    }
}

private extension Color {
    static let brandSky = Color(red: 0x24 / 255, green: 0xB4 / 255, blue: 0xE9 / 255)
    static let brandNavy = Color(red: 0x1F / 255, green: 0x36 / 255, blue: 0x67 / 255)
}

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.white.opacity(0.92))
                .activitySystemActionForegroundColor(Color.brandNavy)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.kind == .meeting ? "Meeting" : "Note", systemImage: context.state.pausedAt == nil ? "mic.fill" : "pause.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.brandSky)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.startedAt...Date.distantFuture, pauseTime: context.state.pausedAt, countsDown: false)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 80)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.attributes.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        PauseButton(context: context, foreground: .white)
                        StopButton(isFinishing: context.state.isFinishing, foreground: .white)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.pausedAt == nil ? "mic.fill" : "pause.fill").foregroundStyle(.red)
            } compactTrailing: {
                Text(timerInterval: context.state.startedAt...Date.distantFuture, pauseTime: context.state.pausedAt, countsDown: false)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
                    .foregroundStyle(Color.brandSky)
            } minimal: {
                Image(systemName: context.state.pausedAt == nil ? "mic.fill" : "pause.fill").foregroundStyle(.red)
            }
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: context.state.pausedAt == nil ? "mic.fill" : "pause.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.brandNavy)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.brandSky))
            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.pausedAt != nil ? "Paused" : context.attributes.kind == .meeting ? "Recording" : "Dictating note")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.brandNavy.opacity(0.6))
                Text(context.attributes.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.brandNavy)
                    .lineLimit(1)
                Text(timerInterval: context.state.startedAt...Date.distantFuture, pauseTime: context.state.pausedAt, countsDown: false)
                    .font(.title2.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.brandNavy)
            }
            Spacer()
            PauseButton(context: context)
            StopButton(isFinishing: context.state.isFinishing)
        }
        .padding(16)
    }
}

/// Only meetings can pause; a dictated note shows no button here.
private struct PauseButton: View {
    let context: ActivityViewContext<RecordingActivityAttributes>
    /// Navy on the light Lock Screen card, white on the black Dynamic Island.
    var foreground = Color.brandNavy

    private var isPaused: Bool { context.state.pausedAt != nil }

    var body: some View {
        if context.attributes.kind == .meeting {
            Button(intent: PauseRecordingIntent()) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(foreground)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.brandSky.opacity(0.16)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPaused ? "Resume Recording" : "Pause Recording")
        }
    }
}

private struct StopButton: View {
    let isFinishing: Bool
    var foreground = Color.brandNavy

    var body: some View {
        Button(intent: StopRecordingIntent()) {
            Label(isFinishing ? "Saving" : "Stop", systemImage: isFinishing ? "hourglass" : "stop.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.brandSky.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .disabled(isFinishing)
    }
}
