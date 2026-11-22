import SwiftData
import SwiftUI

/// The suggested bowls of one inbox entry. Any other bowl is in the long press of the row, as in every list.
struct FilingBar: View {
    let note: Note
    let projects: [NoteFolder]

    @Environment(\.modelContext) private var context

    private var suggested: [NoteFolder] { Self.suggested(for: note, among: projects) }

    static func suggested(for note: Note, among projects: [NoteFolder]) -> [NoteFolder] {
        note.suggestedProjectIDs.compactMap { id in projects.first { Projects.key($0) == id && !BowlSharing.shared.isReadOnly($0.id) } }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggested) { project in
                    SuggestionPill(name: project.name) {
                        withAnimation(.snappy) { Undoable.move([note], toBowl: Projects.key(project), named: project.name, in: context) }
                    } onDismiss: {
                        withAnimation(.snappy) { Inbox.dismissSuggestions(note, in: context) }
                    }
                }
            }
            .padding(.leading, ThingsRowIcon.inset)
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 10, trailing: 20))
        .listRowSeparator(.hidden, edges: .top)
    }
}

/// A suggested bowl: the name takes it on, the cross drops it.
struct SuggestionPill: View {
    let name: String
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onAccept) {
                Label(name, systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("File into \(name)")
            .accessibilityHint("Suggested bowl")
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Drop Suggestion")
        }
        .foregroundStyle(Color.brandProject.onFill)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .chunkyPill(fill: .brandProject)
    }
}
