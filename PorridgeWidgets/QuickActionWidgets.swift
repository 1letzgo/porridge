import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Controls (Control Center, Lock Screen, Action button)

struct NewNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "de.letzgo.porridge.control.newNote") {
            ControlWidgetButton(action: NewNoteIntent()) {
                Label("New Note", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Note")
        .description("Opens Porridge with a new note.")
    }
}

struct StartMeetingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "de.letzgo.porridge.control.startMeeting") {
            ControlWidgetButton(action: StartMeetingIntent()) {
                Label("Start Meeting", systemImage: "mic.fill")
            }
        }
        .displayName("Start Meeting")
        .description("Opens Porridge and starts recording a meeting.")
    }
}

// MARK: - Home Screen widget

/// Nothing changes over time: one entry for good.
struct QuickActionsProvider: TimelineProvider {
    struct Entry: TimelineEntry {
        let date: Date
    }

    func placeholder(in context: Context) -> Entry { Entry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now)], policy: .never))
    }
}

/// Two big buttons: record a meeting, write a note.
struct QuickActionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "de.letzgo.porridge.widget.quickActions", provider: QuickActionsProvider()) { _ in
            QuickActionsView()
        }
        .configurationDisplayName("Meeting & Note")
        .description("Start a meeting or write a new note.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct QuickActionsView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let layout = family == .systemMedium ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 10))
        layout {
            ActionTile(intent: StartMeetingIntent(), title: "Meeting", systemImage: "mic.fill", tint: .widgetMeeting)
            ActionTile(intent: NewNoteIntent(), title: "Note", systemImage: "square.and.pencil", tint: .widgetNote)
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }
}

private struct ActionTile<Intent: AppIntent>: View {
    let intent: Intent
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Button(intent: intent) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .bold))
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private extension Color {
    /// The colors of the Meetings and Notes tabs in the app.
    static let widgetMeeting = Color(red: 0x1F / 255, green: 0x36 / 255, blue: 0x67 / 255)
    static let widgetNote = Color(red: 0x24 / 255, green: 0xB4 / 255, blue: 0xE9 / 255)
}
