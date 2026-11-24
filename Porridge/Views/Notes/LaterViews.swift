import SwiftData
import SwiftUI

/// The choices of "Later" for a menu: the quick ones with when they come back, and a date and time of one's own.
struct LaterMenuItems: View {
    let notes: [Note]
    /// "Pick Date & Time…" was chosen.
    var onPick: () -> Void
    var onDone: () -> Void = {}

    @Environment(\.modelContext) private var context

    var body: some View {
        ForEach(InboxSnooze.choices(), id: \.choice) { item in
            Button {
                withAnimation(.snappy) { InboxSnooze.snooze(notes, until: item.date, in: context) }
                onDone()
            } label: {
                Label {
                    Text(item.choice.title)
                    Text(InboxSnooze.timeLabel(item.date))
                } icon: {
                    Image(systemName: item.choice.systemImage)
                }
            }
        }
        Divider()
        Button(action: onPick) { Label("Pick Date & Time…", systemImage: "calendar.badge.clock") }
    }
}

/// "Pick Date & Time…": a day and a time of one's own for "Later", as a sheet of its own (from a Later menu).
struct LaterPickerSheet: View {
    let notes: [Note]
    var onDone: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LaterDatePage(notes: notes) {
                onDone()
                dismiss()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.large])
    }
}

/// The day and time of "Pick Date & Time…": in its own sheet, or pushed in the Later sheet (`LaterSheet`).
struct LaterDatePage: View {
    let notes: [Note]
    /// Put away; the page's owner closes it.
    var onDone: () -> Void

    @Environment(\.modelContext) private var context
    @State private var date = InboxSnooze.date(for: .tomorrow) ?? Date().addingTimeInterval(24 * 3600)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker("Back", selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .tint(.brandNavy)
            Text("Back in the Inbox then, with a notification.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationTitle("Later")
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Later") {
                    if date > Date() {
                        withAnimation(.snappy) { InboxSnooze.snooze(notes, until: date, in: context) }
                        onDone()
                    }
                }
                .accessibilityIdentifier("LaterPick")
            }
        }
        .onAppear {
            if let until = notes.first?.snoozedUntil, until > Date() { date = until }
        }
    }
}
