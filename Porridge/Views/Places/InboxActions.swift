import SwiftData
import SwiftUI

// MARK: - Bowl…

/// "Bowl…": every bowl an Inbox entry can go into, the suggested ones first (✦). Choosing one files it there with the
/// one undo toast. For the row's swipe, Triage's "Other…" and "File" when nothing is suggested.
struct BowlPickerSheet: View {
    let notes: [Note]
    /// Filed (not called on Cancel).
    var onDone: () -> Void = {}

    @Query(sort: \NoteFolder.name) private var projects: [NoteFolder]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Not into a bowl shared with me to view only, and not into an archived one.
        let open = projects.filter { !$0.isArchived && !BowlSharing.shared.isReadOnly($0.id) }
        let suggested = notes.count == 1 ? notes[0].suggestedProjectIDs.compactMap { key in open.first { Projects.key($0) == key } } : []
        let others = open.filter { bowl in !suggested.contains { $0.id == bowl.id } }
        NavigationStack {
            List {
                if !suggested.isEmpty {
                    Section("Suggested") {
                        ForEach(suggested) { row($0, isSuggested: true) }
                    }
                }
                Section(suggested.isEmpty ? "Bowls" : "All Bowls") {
                    ForEach(others) { row($0, isSuggested: false) }
                }
            }
            .overlay {
                if open.isEmpty {
                    EmptyStateView(title: "No Bowls Yet", message: "Make a bowl with + in the Bowls tab.", systemImage: "folder")
                }
            }
            .navigationTitle("Bowl")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        // A sheet: its empty view centers in the sheet, whatever page opened it.
        .emptyStateSheet()
        .presentationDetents([.medium, .large])
    }

    private func row(_ bowl: NoteFolder, isSuggested: Bool) -> some View {
        Button {
            withAnimation(.snappy) { Undoable.move(notes, toBowl: Projects.key(bowl), named: bowl.name, in: context) }
            onDone()
            dismiss()
        } label: {
            Label {
                Text(bowl.name).foregroundStyle(.primary)
            } icon: {
                Image(systemName: isSuggested ? "sparkles" : "folder.fill")
                    .foregroundStyle(Color.brandProject.readable)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(isSuggested ? "\(bowl.name), suggested" : bowl.name)
    }
}

// MARK: - "✦ Bowl"

/// The suggested bowl of an Inbox entry as one violet word in its row's footer ("✦ Reading"); a tap files it there,
/// with the one undo toast. Replaces the old pill bar under the row.
struct SuggestionWord: View {
    let name: String
    var onFile: () -> Void

    var body: some View {
        Button(action: onFile) {
            HStack(spacing: 3) {
                Image(systemName: "sparkles").imageScale(.small)
                Text(name).lineLimit(1)
            }
            .fontWeight(.semibold)
            .foregroundStyle(Color.brandProject.readable)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -6)
        .accessibilityLabel("File into \(name)")
        .accessibilityHint("Suggested bowl")
        .accessibilityIdentifier("SuggestedBowl")
    }
}
