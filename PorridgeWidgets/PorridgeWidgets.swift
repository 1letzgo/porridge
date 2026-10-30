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
                    Label(context.attributes.kind == .meeting ? "Meeting" : "Note", systemImage: "mic.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.brandSky)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
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
                        StopButton(isFinishing: context.state.isFinishing)
                    }
                }
            } compactLeading: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            } compactTrailing: {
                Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .frame(maxWidth: 44)
                    .foregroundStyle(Color.brandSky)
            } minimal: {
                Image(systemName: "mic.fill").foregroundStyle(.red)
            }
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "mic.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.brandSky))
            VStack(alignment: .leading, spacing: 2) {
                Text(context.attributes.kind == .meeting ? "Recording meeting" : "Dictating note")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.brandNavy.opacity(0.6))
                Text(context.attributes.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.brandNavy)
                    .lineLimit(1)
                Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
                    .font(.title2.weight(.bold).monospacedDigit())
                    .foregroundStyle(Color.brandNavy)
            }
            Spacer()
            StopButton(isFinishing: context.state.isFinishing)
        }
        .padding(16)
    }
}

private struct StopButton: View {
    let isFinishing: Bool

    var body: some View {
        Button(intent: StopRecordingIntent()) {
            Label(isFinishing ? "Saving" : "Stop", systemImage: isFinishing ? "hourglass" : "stop.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.brandNavy)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(Color.brandSky.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .disabled(isFinishing)
    }
}
