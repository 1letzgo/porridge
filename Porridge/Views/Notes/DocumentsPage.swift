import SwiftData
import SwiftUI

/// Changes several entries of the Inbox or a bowl at once, while the list is in its selection mode: into a bowl or
/// back to the Inbox, and for documents their kind and sender (as set by hand), paid or not, or merging their PDFs into one.
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
                // Bills of the selection marked as paid at once (other papers are left alone).
                let canPay = !Documents.payable(chosenNotes).isEmpty
                Menu {
                    Button { change(.paid(true)) } label: { Label("Mark as Paid", systemImage: "checkmark.circle") }
                    Button { change(.paid(false)) } label: { Label("Mark as Unpaid", systemImage: "creditcard") }
                } label: {
                    actionLabel("Paid", systemImage: "checkmark.circle", isOn: canPay)
                }
                .disabled(!canPay)
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

/// What a stored file is as a document, as a chip in the row of a note's bowls: its kind (and sender, kept short);
/// "+ Document" while nothing is known, so any file can be marked as one. A tap opens the sheet to set it; date and amount are there and in the list row.
struct DocumentChip: View {
    let note: Note
    @Environment(\.modelContext) private var context
    @State private var editing = false

    var body: some View {
        let info = note.documentInfo ?? DocumentInfo()
        let kind = info.kind ?? .other
        Group {
            if info.isEmpty {
                // Nothing known yet: neutral and outlined, like an offer to add something.
                Button { editing = true } label: {
                    Label("Document", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1))
                        .contentShape(Capsule())
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Document Details")
            } else {
                // The app's orange as a wash, like the bowls' violet and the tags' sky: the symbol in its readable shade,
                // the text plain, and the cross that takes it away, as on every other chip.
                HStack(spacing: 6) {
                    Button { editing = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: kind.symbol).font(.caption).foregroundStyle(Color.brandLinkText)
                            Text(info.shortLabel).lineLimit(1).foregroundStyle(.primary)
                            // Open with its due day, overdue in a quiet red, paid in grey.
                            if let status = info.paymentStatus(), let label = info.paymentLabel() {
                                Text("·").foregroundStyle(.secondary)
                                Text(label)
                                    .lineLimit(1)
                                    .foregroundStyle(status == .overdue ? Color.brandDangerText : status == .paid ? Color.secondary : Color.primary)
                                    .layoutPriority(1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(info.sentence)
                    .accessibilityHint("Edit")
                    Button { withAnimation(.snappy) { Undoable.clearDocument(note, in: context) } } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove Document Details")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: info.paymentStatus() == nil ? 260 : 320)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.brandLink.opacity(0.2), in: Capsule())
                .contextMenu {
                    if info.offersPaid { PaidButton(notes: [note]) }
                }
            }
        }
        .sheet(isPresented: $editing) { DocumentInfoSheet(note: note) }
    }
}

/// "Mark as Paid" for documents that can be paid, or "Mark as Unpaid" when all of them are paid already. For a
/// row's or a chip's context menu and the selection bar.
struct PaidButton: View {
    let notes: [Note]
    @Environment(\.modelContext) private var context

    var body: some View {
        let payable = Documents.payable(notes)
        let allPaid = !payable.isEmpty && payable.allSatisfy { $0.documentInfo?.paid == true }
        Button {
            withAnimation(.snappy) { Undoable.apply(.paid(!allPaid), to: payable, in: context) }
        } label: {
            Label(allPaid ? "Mark as Unpaid" : "Mark as Paid", systemImage: allPaid ? "creditcard" : "checkmark.circle")
        }
        .disabled(payable.isEmpty)
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
    @State private var hasDue = false
    @State private var due = Date()
    @State private var isPaid = false
    @State private var paidDate = Date()

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
                // Only for a paper that asks for payment (or whose kind says nothing): the day to pay by, and paid.
                if DocumentInfo(kind: kind).canBePaid {
                    Section {
                        Toggle("Due Date", isOn: $hasDue.animation())
                        if hasDue {
                            DatePicker("Pay By", selection: $due, displayedComponents: .date)
                        }
                        Toggle("Paid", isOn: $isPaid.animation())
                        if isPaid {
                            DatePicker("Paid On", selection: $paidDate, displayedComponents: .date)
                        }
                    } header: {
                        Text("Payment")
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
        if let dueDate = info.dueDate {
            hasDue = true
            due = dueDate
        }
        isPaid = info.paid
        paidDate = DocumentInfo.date(fromDay: info.paidDay) ?? Date()
    }

    private func save() {
        let payable = DocumentInfo(kind: kind).canBePaid
        let info = DocumentInfo(
            kind: kind,
            day: hasDate ? DocumentInfo.dayKey(date) : nil,
            correspondent: sender,
            amount: DocumentExtractor.typedAmount(amount, currency: currency),
            dueDay: payable && hasDue ? DocumentInfo.dayKey(due) : nil,
            isPaid: payable && isPaid ? true : nil,
            paidDay: payable && isPaid ? DocumentInfo.dayKey(paidDate) : nil
        )
        Documents.set(info, on: note, in: context)
    }
}
