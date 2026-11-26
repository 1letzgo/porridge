import SwiftData
import SwiftUI

/// The Inbox, the second place: everything in no bowl (it stays there until it is filed). On a phone the Inbox tab's
/// Inbox side (its switch Inbox | To-dos stands above, owner revision 13). No appointments (owner: not even today's;
/// they are in Today, and once filed into a bowl in their bowl). The bundle suggestion (one line) stands over the list.
/// Each entry names its suggested bowl ("✦ Bowl") and swipes to file. While choosing several, "N Selected · Select All"
/// is the first row and the selection bar takes the tab bar's place.
struct InboxPlace: View {
    let notes: [Note]
    let projects: [NoteFolder]
    @Binding var selection: UUID?
    @Binding var isSelecting: Bool
    @Binding var chosen: Set<UUID>
    var onRemove: (Note) -> Void
    @Environment(\.usesSystemBars) private var usesSystemBars

    var body: some View {
        let waiting = Inbox.notes(notes)
        return Group {
            Group {
                if isSelecting {
                    List(selection: $chosen) {
                        if usesSystemBars {
                            // iPad: "N Selected · Select All" as the list's pinned header (`PadPageBar.inList`).
                            Section {
                                newRows(waiting)
                            } header: {
                                NoteSelectionHeader(notes: waiting, chosen: $chosen)
                                    .padding(.top, 4)
                                    .padPinnedHeader()
                            }
                        } else {
                            newRows(waiting)
                        }
                    }
                    .environment(\.editMode, .constant(.active))
                } else {
                    List(selection: $selection) {
                        if usesSystemBars {
                            // iPad: the bundle suggestion as the entries' pinned header (`PadPageBar.inList`);
                            // without a suggestion it has no height.
                            Section {
                                newRows(waiting)
                            } header: {
                                InboxBundleCard(notes: notes, projects: projects, sideInset: 20)
                                    .padPinnedHeader()
                            }
                        } else {
                            newRows(waiting)
                        }
                    }
                }
            }
            .cardList()
            .overlay {
                // The whole page is empty: the message in its middle (adding is the "+" of the tab bar right below).
                if !isSelecting, waiting.isEmpty {
                    EmptyStateView(title: Self.emptyTitle, message: Self.emptyMessage)
                }
            }
        }
        // Phone: above the list. iPad: inside it (the selection header, the bundle suggestion), so the large title
        // stays sharp.
        .pageTopBar(onPad: .inList) {
            Group {
                if isSelecting {
                    NoteSelectionHeader(notes: waiting, chosen: $chosen)
                } else {
                    // Entries that belong together: one suggestion for a new bowl at a time (`InboxBundler`).
                    InboxBundleCard(notes: notes, projects: projects)
                }
            }
            .emptyStateBar()
        }
        // The selection bar in the tab bar's place (`NotesView` hides the tab bar while choosing).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                NoteSelectionBar(notes: waiting, chosen: $chosen)
            }
        }
    }

    private func newRows(_ waiting: [Note]) -> some View {
        ForEach(waiting) { note in
            // While choosing, the suggestion gives way to the selection.
            NoteListRow(note: note, inInbox: true, suggestion: isSelecting ? nil : EntryMeta.suggestion(for: note, bowls: projects)) { onRemove(note) }
                .lastInSection(note.id == waiting.last?.id)
        }
    }

    static let emptyTitle = "Inbox Empty"
    static let emptyMessage = "Everything is filed into a bowl. New things land here first and stay until they are filed."
}

