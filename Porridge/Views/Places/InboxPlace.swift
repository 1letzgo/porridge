import SwiftData
import SwiftUI

/// The Inbox, the second place: what is new or in no bowl, and what was put away for later, as the two halves of
/// one segment (New / Later) in the first row of the content. New shows the bundle suggestion above its entries.
struct InboxPlace: View {
    let notes: [Note]
    let projects: [NoteFolder]
    @Binding var selection: UUID?
    @Binding var isSelecting: Bool
    @Binding var chosen: Set<UUID>
    /// The Later half of the segment.
    @Binding var showsLater: Bool
    var onRemove: (Note) -> Void
    /// "Add" of the empty Inbox: the Add sheet.
    var onAdd: () -> Void
    var onEndSelecting: () -> Void

    var body: some View {
        // Read so that an entry coming back from later shows up.
        _ = InboxSnoozeScheduler.shared.tick
        let waiting = Inbox.notes(notes)
        let later = InboxSnooze.snoozed(notes)
        let buckets = projects.filter { !$0.isArchived }
        return VStack(spacing: 0) {
            if isSelecting {
                NoteSelectionBar(notes: waiting, chosen: $chosen, offersLater: true, showsDone: false, onDone: onEndSelecting)
            } else {
                Picker("Inbox", selection: $showsLater.animation(.snappy)) {
                    Text("New \(waiting.count)").tag(false)
                    Text("Later \(later.count)").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .accessibilityIdentifier("InboxSegment")
                if !showsLater {
                    // Entries that belong together: one suggestion for a new bowl at a time (`InboxBundler`).
                    InboxBundleCard(notes: notes, projects: projects)
                        .padding(.horizontal)
                        .padding(.top, 4)
                }
            }
            Group {
                if showsLater {
                    List(selection: $selection) {
                        ForEach(later) { note in
                            NoteListRow(note: note) { onRemove(note) }
                                .lastInSection(note.id == later.last?.id)
                        }
                    }
                } else if isSelecting {
                    List(selection: $chosen) { newRows(waiting, buckets: buckets) }
                        .environment(\.editMode, .constant(.active))
                } else {
                    List(selection: $selection) { newRows(waiting, buckets: buckets) }
                }
            }
            .cardList()
            .overlay {
                if showsLater, later.isEmpty {
                    EmptyStateView(title: "Nothing for Later", message: "Put an entry away with a swipe to the left: it comes back here at the time you choose.", systemImage: "clock")
                } else if !showsLater, waiting.isEmpty {
                    empty(later: later)
                }
            }
        }
        .onChange(of: showsLater) {
            if showsLater, isSelecting { onEndSelecting() }
        }
    }

    @ViewBuilder
    private func newRows(_ waiting: [Note], buckets: [NoteFolder]) -> some View {
        ForEach(waiting) { note in
            let isLast = note.id == waiting.last?.id
            // While choosing, the suggestions give way to the selection.
            if isSelecting || FilingBar.suggested(for: note, among: buckets).isEmpty {
                NoteListRow(note: note, inInbox: true) { onRemove(note) }
                    .lastInSection(isLast)
            } else {
                NoteListRow(note: note, inInbox: true) { onRemove(note) }
                FilingBar(note: note, projects: buckets)
                    .lastInSection(isLast)
            }
        }
    }

    /// Nothing new: one sentence, one way to add, and when what is away comes back.
    private func empty(later: [Note]) -> some View {
        ContentUnavailableView {
            Label {
                Text("Inbox Empty")
            } icon: {
                Image("Bowl")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        } description: {
            Text("Everything is filed into a bowl. New things land here first.")
        } actions: {
            Button(action: onAdd) {
                Label("Add", systemImage: "plus")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.brandSky)
            .accessibilityIdentifier("InboxEmptyAdd")
            if let next = later.compactMap(\.snoozedUntil).min() {
                Text(later.count == 1
                     ? "1 entry comes back from Later · \(InboxSnooze.timeLabel(next))"
                     : "\(later.count) entries come back from Later · next \(InboxSnooze.timeLabel(next))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
