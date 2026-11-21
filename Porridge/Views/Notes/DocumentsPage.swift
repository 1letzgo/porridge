import SwiftData
import SwiftUI

/// Every document across the inbox and the bowls (`Documents`): narrowed by kind and sender, by the date on the
/// document under its year. Only a view: the documents stay where they are filed.
struct DocumentsPage: View {
    let notes: [Note]
    /// The note open in the detail column.
    @Binding var selection: UUID?
    /// Moves a note to the trash.
    var onRemove: (Note) -> Void

    @Query(sort: \NoteFolder.name) private var projects: [NoteFolder]
    @State private var kind: DocumentKind?
    @State private var correspondent: String?

    var body: some View {
        let all = Documents.all(notes)
        let shown = Documents.filtered(all, kind: kind, correspondent: correspondent)
        let groups = Documents.yearGroups(shown)
        let names = Dictionary(projects.map { (Projects.key($0), $0.name) }, uniquingKeysWith: { a, _ in a })
        VStack(spacing: 0) {
            if !all.isEmpty {
                filters(all)
                    .padding(.bottom, Look.headerGap)
            }
            List(selection: $selection) {
                ForEach(Array(groups.enumerated()), id: \.element.title) { index, group in
                    Section {
                        ForEach(group.notes) { note in
                            // The bowls a document is in, or none: it waits in the inbox.
                            NoteListRow(note: note, buckets: note.projectIDs.compactMap { names[$0] }) { onRemove(note) }
                                .lastInSection(note.id == group.notes.last?.id)
                        }
                    } header: {
                        ListHeader(title: group.title, count: group.notes.count, tint: .brandNavy, isFirst: index == 0)
                    }
                }
            }
            .cardList()
            .roomForFloatingButtons()
            .overlay {
                if all.isEmpty {
                    EmptyStateView(
                        title: "No Documents Yet",
                        message: "Scan a letter, or import a PDF or a photo of a receipt. Porridge reads its text and tells what it is.",
                        systemImage: "doc.text"
                    )
                } else if shown.isEmpty {
                    EmptyStateView(title: "No Documents", message: "None fit the filter.", systemImage: "doc.text")
                }
            }
        }
    }

    /// The kinds with how many documents each has, then the senders as a menu.
    private func filters(_ all: [Note]) -> some View {
        let senders = Documents.correspondents(all)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", count: all.count, isOn: kind == nil) { kind = nil }
                ForEach(Documents.kindCounts(all), id: \.kind) { entry in
                    chip(entry.kind.title, count: entry.count, isOn: kind == entry.kind) {
                        kind = kind == entry.kind ? nil : entry.kind
                    }
                }
                // Also while a sender is chosen that has no documents any more: it can still be let go.
                if !senders.isEmpty || correspondent != nil {
                    Menu {
                        Button { correspondent = nil } label: {
                            if correspondent == nil { Label("All Senders", systemImage: "checkmark") } else { Text("All Senders") }
                        }
                        Divider()
                        ForEach(senders, id: \.name) { sender in
                            Button { correspondent = sender.name } label: {
                                if correspondent == sender.name {
                                    Label("\(sender.name) (\(sender.count))", systemImage: "checkmark")
                                } else {
                                    Text("\(sender.name) (\(sender.count))")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "person.crop.square")
                            Text(correspondent ?? String(localized: "Sender")).lineLimit(1)
                            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(correspondent == nil ? Color.primary : Color.brandOnNavy)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(correspondent == nil ? Color.brandNavy.opacity(0.1) : Color.brandNavy, in: Capsule())
                    }
                    .accessibilityLabel("Filter by Sender")
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func chip(_ title: String, count: Int, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy) { action() } } label: {
            HStack(spacing: 4) {
                Text(title)
                Text("\(count)").foregroundStyle(isOn ? Color.brandOnNavy.opacity(0.8) : .secondary)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isOn ? Color.brandOnNavy : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isOn ? Color.brandNavy : Color.brandNavy.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
