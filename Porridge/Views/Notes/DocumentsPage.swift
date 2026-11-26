import SwiftData
import SwiftUI

/// The first row of a list while choosing several entries (Inbox, a bowl): "3 Selected" and Select All / None.
struct NoteSelectionHeader: View {
    /// The entries of the list, in its order.
    let notes: [Note]
    @Binding var chosen: Set<UUID>
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let all = !notes.isEmpty && chosen.count == notes.count
        let large = typeSize.isAccessibilitySize
        (large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())) {
            Text(chosen.isEmpty ? String(localized: "Select Entries") : String(localized: "\(chosen.count) Selected"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(chosen.isEmpty ? .secondary : .primary)
                .accessibilityIdentifier("SelectionCount")
            if !large { Spacer(minLength: 8) }
            Button(all ? "Select None" : "Select All") {
                withAnimation(.snappy) { chosen = all ? [] : Set(notes.map(\.id)) }
            }
            .font(.subheadline.weight(.semibold))
            .disabled(notes.isEmpty)
            .accessibilityIdentifier("SelectAll")
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .padding(.bottom, Look.headerGap)
    }
}

/// Changes several entries of the Inbox or a bowl at once: the bar that takes the tab bar's place while choosing. Three
/// fixed buttons, nothing scrolls: Move (into a bowl or back to the Inbox), Done (to-dos) and More
/// (Document Kind, Set Sender…, Merge PDFs…, Delete). What does not apply to the chosen entries is dimmed.
struct NoteSelectionBar: View {
    /// The entries of the list, in its order.
    let notes: [Note]
    @Binding var chosen: Set<UUID>

    @Query(sort: \NoteFolder.name) private var projects: [NoteFolder]
    @Environment(\.modelContext) private var context
    @Environment(ProcessingService.self) private var processing
    @State private var askingSender = false
    @State private var senderText = ""
    @State private var choosingMergeTarget = false
    /// Merged into the target: the others, offered for deletion.
    @State private var mergedAway: [Note] = []
    @State private var error: String?
    /// A merge is running: the bar waits.
    @State private var isWorking = false

    /// The chosen entries, in the order of the list.
    private var chosenNotes: [Note] { notes.filter { chosen.contains($0.id) } }

    /// Kind and sender belong to documents: only offered when every chosen entry is one.
    private var allDocuments: Bool {
        let notes = chosenNotes
        return !notes.isEmpty && notes.allSatisfy { $0.isStored && !$0.attachments.isEmpty }
    }

    var body: some View {
        // Not into a bowl shared with me to view only.
        let active = projects.filter { !$0.isArchived && !BowlSharing.shared.isReadOnly($0.id) }
        let picked = chosenNotes
        let openTodos = picked.filter { $0.isTodo && !$0.isDone && !BowlSharing.shared.isReadOnly($0) }
        let canMerge = allDocuments && DocumentFiles.mergeable(picked).count >= 2
        HStack(spacing: 0) {
            Menu {
                Button { change(.move(toBowl: nil)) } label: { Label("Inbox", systemImage: "tray") }
                Divider()
                ForEach(active) { bowl in
                    Button { change(.move(toBowl: Projects.key(bowl))) } label: { Label(bowl.name, systemImage: "folder") }
                }
            } label: {
                item("Move", systemImage: "folder")
            }
            .disabled(picked.isEmpty)
            .accessibilityIdentifier("SelectionMove")
            Button {
                withAnimation(.snappy) { Undoable.done(openTodos, in: context) }
            } label: {
                item("Done", systemImage: "checkmark.square")
            }
            .disabled(openTodos.isEmpty)
            .accessibilityLabel("Mark as Done")
            .accessibilityIdentifier("SelectionDone")
            Menu {
                Menu {
                    Button("Not Set") { change(.kind(nil)) }
                    ForEach(DocumentKind.allCases) { kind in
                        Button { change(.kind(kind)) } label: { Label(kind.title, systemImage: kind.symbol) }
                    }
                } label: {
                    Label("Document Kind", systemImage: "tag")
                }
                .disabled(!allDocuments)
                Button {
                    senderText = ""
                    askingSender = true
                } label: {
                    Label("Set Sender…", systemImage: "person.crop.square")
                }
                .disabled(!allDocuments)
                Button { choosingMergeTarget = true } label: {
                    Label(canMerge ? "Merge \(DocumentFiles.mergeable(picked).count) PDFs…" : "Merge PDFs…", systemImage: "arrow.triangle.merge")
                }
                .disabled(!canMerge)
                Divider()
                Button(role: .destructive) {
                    withAnimation(.snappy) { Undoable.trash(picked, in: context) }
                } label: {
                    Label(picked.count == 1 ? "Delete 1 Entry" : "Delete \(picked.count) Entries", systemImage: "trash")
                }
                .disabled(picked.isEmpty)
            } label: {
                item("More", systemImage: "ellipsis.circle")
            }
            // In the order of the design (Delete last), also when the menu opens upwards from the bar.
            .menuOrder(.fixed)
            .disabled(picked.isEmpty)
            .accessibilityIdentifier("SelectionMore")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .frame(height: 54)
        .modifier(BarBackground())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 10)
        // Where the bar stands: on an iPad the undo toast centers over it, in the list column (`RootView`).
        .background(GeometryReader { Color.clear.preference(key: SelectionBarFrameKey.self, value: $0.frame(in: .global)) })
        .padding(.bottom, 4)
        .disabled(isWorking)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        // Only what the list shows can be chosen: an entry moved out of it (or deleted) leaves the selection.
        .onChange(of: notes.map(\.id), initial: true) { _, ids in
            let visible = chosen.intersection(ids)
            if visible != chosen { chosen = visible }
        }
        .alert("Sender", isPresented: $askingSender) {
            TextField("Company, office or person", text: $senderText)
            Button("Cancel", role: .cancel) {}
            Button("Set") { change(.sender(senderText)) }
        } message: {
            Text("For the \(chosenNotes.count) selected documents. Leave it empty to remove the sender.")
        }
        .confirmationDialog("Merge into Which Document?", isPresented: $choosingMergeTarget, titleVisibility: .visible) {
            let documents = DocumentFiles.mergeable(chosenNotes)
            ForEach(documents) { target in
                Button(target.displayTitle) { Task { await merge(into: target, from: documents) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The pages of the others are added at its end, in the order of the list. It keeps what it is.")
        }
        .alert(
            "Delete the Merged Documents?",
            isPresented: Binding(get: { !mergedAway.isEmpty }, set: { if !$0 { mergedAway = [] } })
        ) {
            Button("Move \(mergedAway.count) to Recently Deleted", role: .destructive) {
                mergedAway.forEach { NoteStore.trash($0, in: context) }
                mergedAway = []
            }
            Button("Keep Them", role: .cancel) { mergedAway = [] }
        } message: {
            Text("Their pages are in the merged document now.")
        }
        .alert("Could Not Merge", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    /// One of the three buttons: symbol over word, navy; dimmed while it does not apply.
    private func item(_ title: LocalizedStringKey, systemImage: String) -> some View {
        SelectionBarItem(title: title, systemImage: systemImage)
    }

    private func change(_ change: Documents.BulkChange) {
        guard !chosen.isEmpty else { return }
        let bowlName: String? = if case .move(let bowl?) = change { projects.first { Projects.key($0) == bowl }?.name } else { nil }
        withAnimation(.snappy) { Undoable.apply(change, to: chosenNotes, bowlName: bowlName, in: context) }
    }

    private func merge(into target: Note, from documents: [Note]) async {
        let others = documents.filter { $0.id != target.id }
        isWorking = true
        defer { isWorking = false }
        do {
            try await DocumentFiles.merge(others, into: target, context: context, processing: processing)
            chosen = []
            // Only entries that held nothing but the merged PDF are offered for deletion.
            mergedAway = DocumentFiles.deletableAfterMerge(others)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A button of the selection bar: symbol over a small word, like a tab.
private struct SelectionBarItem: View {
    let title: LocalizedStringKey
    let systemImage: String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .frame(height: 24)
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        // Like the tab bar it replaces: the words stop growing at the largest text sizes, and a long press shows
        // the button big (the large content viewer).
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .foregroundStyle(isEnabled ? Color.brandNavy.readable : Color.secondary.opacity(0.6))
        .frame(maxWidth: .infinity, minHeight: 48)
        .contentShape(Rectangle())
        .accessibilityShowsLargeContentViewer {
            Label(title, systemImage: systemImage)
        }
    }
}

/// Sets what a document is by hand; from then on it is kept as set.
struct DocumentInfoSheet: View {
    let note: Note

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var kind: DocumentKind?
    @State private var hasDate = false
    @State private var date = Date()
    @State private var sender = ""
    @State private var amount = ""
    @State private var currency: String?

    static let currencies = ["EUR", "USD", "GBP", "CHF"]

    var body: some View {
        NavigationStack {
            Form {
                Picker("Kind", selection: $kind) {
                    Text("Not Set").tag(DocumentKind?.none)
                    ForEach(DocumentKind.allCases) { kind in
                        Label(kind.title, systemImage: kind.symbol).tag(DocumentKind?.some(kind))
                    }
                }
                Section {
                    TextField("Sender", text: $sender)
                        .textContentType(.organizationName)
                    Toggle("Date", isOn: $hasDate.animation())
                    if hasDate {
                        DatePicker("Date on the Document", selection: $date, displayedComponents: .date)
                    }
                }
                Section {
                    HStack {
                        TextField("Amount", text: $amount)
                            .keyboardType(.decimalPad)
                        Picker("Currency", selection: $currency) {
                            Text("None").tag(String?.none)
                            // A currency the model read that is not in the short list stays choosable.
                            ForEach(Self.currencies + (currency.map { Self.currencies.contains($0) ? [] : [$0] } ?? []), id: \.self) {
                                Text($0).tag(String?.some($0))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                } footer: {
                    if !amount.isEmpty, DocumentExtractor.typedAmount(amount, currency: currency) == nil {
                        Text("Not a number.").foregroundStyle(Color.brandDangerText)
                    }
                }
            }
            .brandNavigationTitle("Document")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(!amount.isEmpty && DocumentExtractor.typedAmount(amount, currency: currency) == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear(perform: load)
    }

    private func load() {
        let info = note.documentInfo ?? DocumentInfo()
        kind = info.kind
        if let day = info.date {
            hasDate = true
            date = day
        }
        sender = info.correspondent ?? ""
        if let (value, code) = DocumentInfo.parts(ofAmount: info.amount) {
            amount = value.formatted(.number.precision(.fractionLength(2)).grouping(.never))
            currency = code
        } else {
            currency = Locale.current.currency?.identifier ?? "EUR"
        }
    }

    private func save() {
        let info = DocumentInfo(
            kind: kind,
            day: hasDate ? DocumentInfo.dayKey(date) : nil,
            correspondent: sender,
            amount: DocumentExtractor.typedAmount(amount, currency: currency)
        )
        Documents.set(info, on: note, in: context)
    }
}
