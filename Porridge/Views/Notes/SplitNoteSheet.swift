import SwiftData
import SwiftUI

/// "Split into Bowl…": the proposal for a long note (a new bowl and the entries cut out of it), to be checked before
/// anything is made. Entries can be renamed or left out; nothing happens before "Create".
struct SplitNoteSheet: View {
    let note: Note
    let onCreate: (BowlChange) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \NoteFolder.name) private var bowls: [NoteFolder]
    @State private var proposal: SplitProposal
    @State private var moveSource = true
    @State private var isAsking = false
    @State private var modelNote: String?

    init(note: Note, onCreate: @escaping (BowlChange) -> Void) {
        self.note = note
        self.onCreate = onCreate
        _proposal = State(initialValue: NoteSplitter.structural(title: note.title, text: NoteSplitter.material(of: note)))
    }

    private var existingBowl: Bool {
        let name = proposal.bowlName.trimmingCharacters(in: .whitespacesAndNewlines)
        return bowls.contains { !$0.isArchived && !BowlSharing.shared.isReadOnly($0.id) && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    private var canCreate: Bool {
        !proposal.bowlName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!proposal.included.isEmpty || moveSource)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Bowl Name", text: $proposal.bowlName)
                        .font(.body.weight(.semibold))
                        .accessibilityIdentifier("SplitBowlName")
                } header: {
                    Text("Bowl")
                } footer: {
                    if existingBowl { Text("A bowl of this name exists: the entries go into it.") }
                }

                let notes = proposal.entries.indices.filter { !proposal.entries[$0].isTodo }
                if !notes.isEmpty {
                    Section("Notes") {
                        ForEach(notes, id: \.self) { index in row(index) }
                    }
                }
                let todos = proposal.entries.indices.filter { proposal.entries[$0].isTodo }
                if !todos.isEmpty {
                    Section("To-dos") {
                        ForEach(todos, id: \.self) { index in row(index) }
                    }
                }
                if proposal.entries.isEmpty {
                    Section {
                        Text("Nothing to split off. The note can still go into the new bowl.").foregroundStyle(.secondary)
                    }
                }

                Section {
                    Toggle("Move This Note into the Bowl", isOn: $moveSource)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The note itself stays as it is.")
                        if isAsking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Asking the model for a better split…")
                            }
                        } else if let label = proposal.modelLabel {
                            Text("Proposed by \(label).")
                        } else if let modelNote {
                            Text(modelNote)
                        } else {
                            Text("Split by the note's headings, paragraphs and task lines.")
                        }
                    }
                }
            }
            .navigationTitle("Split into Bowl")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(!canCreate || isAsking)
                        .accessibilityIdentifier("SplitCreate")
                }
            }
            .task { await askModel() }
        }
    }

    private func row(_ index: Int) -> some View {
        let entry = proposal.entries[index]
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                proposal.entries[index].isIncluded.toggle()
            } label: {
                Image(systemName: entry.isIncluded ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(entry.isIncluded ? (entry.isTodo ? Color.brandTaskText : Color.brandProject) : .secondary)
                    .contentShape(Rectangle().inset(by: -10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(entry.title))
            .accessibilityValue(entry.isIncluded ? "Selected" : "Not Selected")
            .accessibilityAddTraits(.isToggle)
            VStack(alignment: .leading, spacing: 3) {
                TextField(entry.isTodo ? "To-do" : "Title", text: $proposal.entries[index].title, axis: .vertical)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(entry.isIncluded ? .primary : .secondary)
                if !entry.text.isEmpty {
                    Text(NoteText.plainLines(entry.text).joined(separator: " "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let due = entry.dueDay {
                    Label(Todos.dueLabel(due), systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A model that can answer without a download proposes a better split; the structural one stays on failure.
    private func askModel() async {
        guard let model = NoteSplitter.availableModel else {
            modelNote = nil
            return
        }
        let text = NoteSplitter.material(of: note)
        guard text.count <= NoteSplitter.modelLimit(model) else { return }
        isAsking = true
        defer { isAsking = false }
        do {
            let better = try await NoteSplitter.proposeWithModel(note, model: model)
            withAnimation(.snappy) { proposal = better }
        } catch {
            modelNote = "The model could not split the note; this split follows its structure."
        }
    }

    private func create() {
        guard let change = NoteSplitter.apply(proposal, from: note, moveSource: moveSource, in: context) else { return }
        onCreate(change)
        dismiss()
    }
}

/// Shown on the note's page after a split, while it can be taken back.
struct BowlChangeBanner: View {
    let text: String
    let onUndo: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label(text, systemImage: "folder.badge.plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.brandNavy)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("Undo", action: onUndo)
                .buttonStyle(PillButtonStyle())
            Button(action: onClose) {
                Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .flatPanel()
    }
}
