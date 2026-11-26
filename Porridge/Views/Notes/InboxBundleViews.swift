import SwiftData
import SwiftUI

/// On top of the Inbox: one suggestion to put entries that belong together into a new bowl (`InboxBundler`). Once
/// that is done, the way back is the one undo toast.
struct InboxBundleCard: View {
    let notes: [Note]
    let projects: [NoteFolder]
    /// Its margin to the sides: the page's (16) in the bar over the list, none under the Inbox's "New" header, whose
    /// insets it shares.
    var sideInset: CGFloat = 16

    @Environment(\.modelContext) private var context
    @State private var bundle: InboxBundle?
    @State private var reviewing: InboxBundle?

    /// What the suggestion depends on: the inbox's entries, their suggestions and tags, and the index's vectors.
    private var signature: String {
        let inbox = notes.filter(\.isInInbox).map { "\($0.id)\($0.suggestedProjectIDs.count)\($0.labels.count)" }.joined()
        return "\(inbox.hashValue)|\(NoteIndex.shared.version)"
    }

    var body: some View {
        // A stack, not a Group: with no suggestion yet a Group has no view, and its task would never run.
        VStack(spacing: 0) {
            if let bundle {
                suggestion(bundle)
                    .padding(.horizontal, sideInset)
                    .padding(.vertical, 4)
            }
        }
        .task(id: signature) {
            // The inbox changes in bursts (a sync, a share); it is looked at once things rest.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let next = InboxBundler.current(notes, projects: projects)
            if next != bundle { withAnimation(.snappy) { bundle = next } }
        }
        .sheet(item: Binding(get: { reviewing.map(ReviewItem.init) }, set: { reviewing = $0?.bundle })) { item in
            InboxBundleSheet(bundle: item.bundle, notes: notes) { change in
                withAnimation(.snappy) { bundle = nil }
                BowlMaking.offerUndo(change, in: context)
            }
        }
    }

    /// "✦ New bowl “Berlin Trip” for 3 entries?", Review…, and the cross. The sentence is whole: where the row is
    /// too narrow for it (a long bowl name, the iPad's list column) it takes up to three lines (it was cut after
    /// "for 3…"); Review… and the cross keep their size. The entries' titles are in the review sheet (and read by
    /// VoiceOver).
    private func suggestion(_ bundle: InboxBundle) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.brandProject.readable)
                .accessibilityHidden(true)
            Text(bundle.line)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.brandProject.readable)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
                .accessibilityHint(titles(bundle))
            Spacer(minLength: 4)
            Button("Review…") { reviewing = bundle }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.brandNavy.readable)
                .fixedSize()
                .accessibilityIdentifier("InboxBundleReview")
            Button {
                withAnimation(.snappy) {
                    InboxBundler.dismiss(bundle)
                    self.bundle = nil
                }
            } label: {
                Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    .frame(width: 26, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Suggestion")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(minHeight: 40)
        .background(Color.brandProject.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.brandProject.opacity(0.25), lineWidth: 1))
    }

    private func titles(_ bundle: InboxBundle) -> String {
        bundle.noteIDs.compactMap { id in notes.first { $0.id == id }?.displayTitle }.joined(separator: " · ")
    }

    private struct ReviewItem: Identifiable {
        let bundle: InboxBundle
        var id: String { bundle.key }
    }
}

/// The entries of a suggested bundle, each with a checkbox, and the bowl's name; "Create" makes the bowl and moves
/// the chosen entries into it.
struct InboxBundleSheet: View {
    let bundle: InboxBundle
    let notes: [Note]
    let onCreate: (BowlChange) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var chosen: Set<UUID>

    init(bundle: InboxBundle, notes: [Note], onCreate: @escaping (BowlChange) -> Void) {
        self.bundle = bundle
        self.notes = notes
        self.onCreate = onCreate
        _name = State(initialValue: bundle.name)
        _chosen = State(initialValue: Set(bundle.noteIDs))
    }

    private var members: [Note] { bundle.noteIDs.compactMap { id in notes.first { $0.id == id } } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bowl") {
                    TextField("Bowl Name", text: $name)
                        .font(.body.weight(.semibold))
                        .accessibilityIdentifier("InboxBundleName")
                }
                Section("Entries") {
                    ForEach(members) { note in
                        let isOn = chosen.contains(note.id)
                        Button {
                            if isOn { chosen.remove(note.id) } else { chosen.insert(note.id) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isOn ? Color.brandProject : .secondary)
                                Image(systemName: note.kindSymbol).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.displayTitle).foregroundStyle(.primary).lineLimit(2)
                                    if !note.preview.isEmpty {
                                        Text(note.preview).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(isOn ? "Selected" : "Not Selected")
                        .accessibilityAddTraits(.isToggle)
                    }
                }
            }
            .navigationTitle(bundle.isExistingBowl ? "Into Bowl" : "New Bowl")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(chosen.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("InboxBundleCreate")
                }
            }
        }
    }

    private func create() {
        let ids = bundle.noteIDs.filter { chosen.contains($0) }
        guard let change = InboxBundler.apply(name: name, noteIDs: ids, notes: notes, in: context) else { return }
        onCreate(change)
        dismiss()
    }
}
