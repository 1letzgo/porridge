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

/// The same choices as a dialog, for the swipe on a row.
struct LaterDialog: ViewModifier {
    let notes: [Note]
    @Binding var isPresented: Bool
    @State private var picking = false
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Later", isPresented: $isPresented, titleVisibility: .visible) {
                ForEach(InboxSnooze.choices(), id: \.choice) { item in
                    Button("\(item.choice.title) · \(InboxSnooze.timeLabel(item.date))") {
                        withAnimation(.snappy) { InboxSnooze.snooze(notes, until: item.date, in: context) }
                    }
                }
                Button("Pick Date & Time…") { picking = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Back in the Inbox then, with a notification.")
            }
            .sheet(isPresented: $picking) { LaterPickerSheet(notes: notes) }
    }
}

extension View {
    func laterDialog(for notes: [Note], isPresented: Binding<Bool>) -> some View {
        modifier(LaterDialog(notes: notes, isPresented: isPresented))
    }
}

/// "Pick Date & Time…": a day and a time of one's own for "Later".
struct LaterPickerSheet: View {
    let notes: [Note]
    var onDone: () -> Void = {}

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var date = InboxSnooze.date(for: .tomorrow) ?? Date().addingTimeInterval(24 * 3600)

    var body: some View {
        NavigationStack {
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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Later") {
                        if date > Date() {
                            withAnimation(.snappy) { InboxSnooze.snooze(notes, until: date, in: context) }
                            onDone()
                        }
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            if let until = notes.first?.snoozedUntil, until > Date() { date = until }
        }
    }
}
