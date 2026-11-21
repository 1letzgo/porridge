import SwiftData
import SwiftUI

/// Changes several entries of the Inbox or a bowl at once, while the list is in its selection mode: into a bowl or
/// back to the Inbox, and for documents their kind and sender (as set by hand) or merging their PDFs into one.
struct NoteSelectionBar: View {
    /// The entries of the list, in its order.
    let notes: [Note]
    @Binding var chosen: Set<UUID>
    var onDone: () -> Void

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
        let active = projects.filter { !$0.isArchived }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button(chosen.count == notes.count ? "Select None" : "Select All") {
                    chosen = chosen.count == notes.count ? [] : Set(notes.map(\.id))
                }
                .font(.subheadline.weight(.semibold))
                Menu {
                    Button { change(.move(toBowl: nil)) } label: { Label("Inbox", systemImage: "tray") }
                    Divider()
                    ForEach(active) { bowl in
                        Button { change(.move(toBowl: Projects.key(bowl))) } label: { Label(bowl.name, systemImage: "folder") }
                    }
                } label: {
                    actionLabel("Move", systemImage: "folder", isOn: !chosen.isEmpty)
                }
                .disabled(chosen.isEmpty)
                Menu {
                    Button("Not Set") { change(.kind(nil)) }
                    ForEach(DocumentKind.allCases) { kind in
                        Button { change(.kind(kind)) } label: { Label(kind.title, systemImage: kind.symbol) }
                    }
                } label: {
                    actionLabel("Kind", systemImage: "tag", isOn: allDocuments)
                }
                .disabled(!allDocuments)
                Button {
                    senderText = ""
                    askingSender = true
                } label: {
                    actionLabel("Sender", systemImage: "person.crop.square", isOn: allDocuments)
                }
                .disabled(!allDocuments)
                let canMerge = allDocuments && DocumentFiles.mergeable(chosenNotes).count >= 2
                Button { choosingMergeTarget = true } label: {
                    actionLabel("Merge", systemImage: "arrow.triangle.merge", isOn: canMerge)
                }
                .disabled(!canMerge)
                Button("Done", action: onDone)
                    .font(.subheadline.weight(.bold))
            }
            .padding(.horizontal, 20)
        }
        .disabled(isWorking)
        .padding(.bottom, Look.headerGap)
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
        .confirmationDialog(
            "Delete the Merged Documents?",
            isPresented: Binding(get: { !mergedAway.isEmpty }, set: { if !$0 { mergedAway = [] } }), titleVisibility: .visible
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

    private func actionLabel(_ title: LocalizedStringKey, systemImage: String, isOn: Bool) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isOn ? Color.brandOnNavy : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isOn ? Color.brandNavy : Color.brandNavy.opacity(0.1), in: Capsule())
    }

    private func change(_ change: Documents.BulkChange) {
        guard !chosen.isEmpty else { return }
        withAnimation(.snappy) { _ = Documents.apply(change, to: chosenNotes, in: context) }
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

/// What a document is, on its page: kind, date, sender and amount, read automatically or set by hand.
struct DocumentInfoCard: View {
    let note: Note
    @State private var editing = false

    var body: some View {
        let info = note.documentInfo ?? DocumentInfo()
        Button { editing = true } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: (info.kind ?? .other).symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.brandNavy)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.kind?.title ?? String(localized: "Document"))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.brandNavy)
                    if info.isEmpty {
                        Text("Add the kind, date, sender and amount.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                            if let sender = info.correspondent { field("From", sender) }
                            if let day = info.dayText { field("Date", day) }
                            if let amount = info.amountText { field("Amount", amount) }
                        }
                        .font(.subheadline)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "pencil")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .flatPanel(.brandNavy, padding: 12)
        .accessibilityLabel(info.isEmpty ? String(localized: "Document details") : info.sentence)
        .accessibilityHint("Edit")
        .sheet(isPresented: $editing) { DocumentInfoSheet(note: note) }
    }

    private func field(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).foregroundStyle(.primary).lineLimit(2)
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
