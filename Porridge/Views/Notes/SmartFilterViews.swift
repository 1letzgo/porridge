import SwiftData
import SwiftUI

// MARK: - In the Bowls place

/// A smart filter in the Bowls place: its name, what it asks for, how many entries fit.
struct SmartFilterRow: View {
    let filter: SmartFilter
    let count: Int
    var onOpen: () -> Void
    var onEdit: () -> Void
    var onRename: () -> Void
    var onDelete: () -> Void

    @Query(sort: \NoteFolder.name) private var projects: [NoteFolder]

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                ThingsRowIcon(systemImage: "line.3.horizontal.decrease", tint: .brandNavy)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(filter.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(SmartFilters.summary(of: filter.criteria, bowlName: bowlName))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardListRow()
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
            Button(action: onEdit) { Label("Edit", systemImage: "slider.horizontal.3") }
                .tint(.brandNavy)
        }
        .contextMenu {
            Button(action: onEdit) { Label("Edit…", systemImage: "slider.horizontal.3") }
            Button(action: onRename) { Label("Rename", systemImage: "pencil") }
            Divider()
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
        .accessibilityIdentifier("SmartFilter-\(filter.name)")
    }

    private func bowlName(_ key: String) -> String? {
        projects.first { Projects.key($0) == key }?.name
    }
}

// MARK: - The filter opened

/// One smart filter opened: the entries that fit, wherever they are. Nothing is moved.
struct SmartFilterPage: View {
    let filter: SmartFilter
    let notes: [Note]
    @Binding var selection: UUID?
    var onRemove: (Note) -> Void

    @Query(sort: \NoteFolder.name) private var projects: [NoteFolder]

    var body: some View {
        // Read so the list follows the index while it loads.
        let _ = NoteIndex.shared.version
        let found = SmartFilters.results(filter.criteria, in: notes)
        let names = Dictionary(projects.map { (Projects.key($0), $0.name) }, uniquingKeysWith: { a, _ in a })
        List(selection: $selection) {
            Section {
                ForEach(found) { note in
                    NoteListRow(note: note, buckets: note.projectIDs.compactMap { names[$0] }) { onRemove(note) }
                        .lastInSection(note.id == found.last?.id)
                }
            } header: {
                ListHeader(
                    title: SmartFilters.summary(of: filter.criteria) { names[$0] }, count: found.count, tint: .brandNavy, isFirst: true
                )
            }
        }
        .cardList()
        .overlay {
            if found.isEmpty {
                EmptyStateView(
                    title: "Nothing Matches", message: "No entry fits this smart filter right now. Edit it to change what it looks for.",
                    systemImage: "line.3.horizontal.decrease"
                )
            }
        }
    }
}

// MARK: - Editing

/// What the editor works on: a new filter (from the search, or empty) or one that exists.
struct SmartFilterDraft: Identifiable {
    let id = UUID()
    /// The filter changed; nil for a new one.
    var existing: SmartFilter?
    var name: String
    var criteria: SmartFilterCriteria

    static func new(from criteria: SmartFilterCriteria) -> SmartFilterDraft {
        SmartFilterDraft(existing: nil, name: "", criteria: criteria)
    }

    static func edit(_ filter: SmartFilter) -> SmartFilterDraft {
        SmartFilterDraft(existing: filter, name: filter.name, criteria: filter.criteria)
    }
}

/// Creates or changes a smart filter: its name and every criterion, with how many entries fit right now.
struct SmartFilterEditor: View {
    let draft: SmartFilterDraft
    let notes: [Note]
    /// Called with the saved filter.
    var onSave: (SmartFilter) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \NoteFolder.name) private var projects: [NoteFolder]

    @State private var name = ""
    @State private var text = ""
    @State private var tags = ""
    @State private var kind: String?
    @State private var source: String?
    @State private var documentKind: String?
    @State private var sender = ""
    @State private var bowl: String?
    @State private var dates = DateMode.any
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var hasFrom = false
    @State private var fromDate = Date()
    @State private var hasTo = false
    @State private var toDate = Date()
    @State private var loaded = false

    enum DateMode: Hashable { case any, year, custom }

    private var criteria: SmartFilterCriteria {
        var result = SmartFilterCriteria()
        result.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        result.tags = tags.split(whereSeparator: { $0 == "," || $0 == " " }).map { Note.cleanTag(String($0)) }.filter { !$0.isEmpty }
        result.kind = kind
        result.source = source
        result.documentKind = documentKind
        result.sender = sender.trimmingCharacters(in: .whitespaces).isEmpty ? nil : sender.trimmingCharacters(in: .whitespaces)
        result.bowl = bowl
        switch dates {
        case .any: break
        case .year:
            result.from = String(format: "%04d-01-01", year)
            result.to = String(format: "%04d-12-31", year)
        case .custom:
            result.from = hasFrom ? DocumentInfo.dayKey(fromDate) : nil
            result.to = hasTo ? DocumentInfo.dayKey(toDate) : nil
        }
        return result
    }

    private var years: [Int] {
        let now = Calendar.current.component(.year, from: Date())
        return Array(Set(Array((now - 15)...(now + 1)) + [year])).sorted(by: >)
    }

    var body: some View {
        let current = criteria
        let count = SmartFilters.results(current, in: notes).count
        NavigationStack {
            Form {
                Section {
                    TextField(SmartFilters.suggestedName(for: current, bowlName: bowlName), text: $name)
                        .accessibilityIdentifier("SmartFilterName")
                } header: {
                    Text("Name")
                }

                Section {
                    TextField("Words", text: $text)
                        .autocorrectionDisabled()
                    TextField("Tags", text: $tags, prompt: Text("Tags, separated by commas"))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Search")
                } footer: {
                    Text("Every word and tag must be in an entry.")
                }

                Section("Entries") {
                    Picker("Kind", selection: $kind) {
                        Text("Any").tag(String?.none)
                        ForEach(SmartFilterKind.allCases, id: \.self) { option in
                            Label(option.title, systemImage: option.symbol).tag(String?.some(option.rawValue))
                        }
                    }
                    Picker("Came In As", selection: $source) {
                        Text("Any").tag(String?.none)
                        ForEach(SmartFilters.sources, id: \.rawValue) { option in
                            Text(option.label).tag(String?.some(option.rawValue))
                        }
                    }
                    Picker("Document Kind", selection: $documentKind) {
                        Text("Any").tag(String?.none)
                        ForEach(DocumentKind.allCases) { option in
                            Label(option.title, systemImage: option.symbol).tag(String?.some(option.rawValue))
                        }
                    }
                    TextField("Sender", text: $sender, prompt: Text("Sender of a document"))
                        .autocorrectionDisabled()
                }

                Section("Date") {
                    Picker("Date", selection: $dates) {
                        Text("Any Time").tag(DateMode.any)
                        Text("Year").tag(DateMode.year)
                        Text("Range").tag(DateMode.custom)
                    }
                    .pickerStyle(.segmented)
                    switch dates {
                    case .any:
                        EmptyView()
                    case .year:
                        Picker("Year", selection: $year) {
                            ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                        }
                    case .custom:
                        Toggle("From", isOn: $hasFrom.animation())
                        if hasFrom { DatePicker("From", selection: $fromDate, displayedComponents: .date).labelsHidden() }
                        Toggle("To", isOn: $hasTo.animation())
                        if hasTo { DatePicker("To", selection: $toDate, displayedComponents: .date).labelsHidden() }
                    }
                }

                Section {
                    Picker("Bowl", selection: $bowl) {
                        Text("Any").tag(String?.none)
                        Text("Inbox").tag(String?.some(SmartFilterCriteria.inbox))
                        ForEach(bowlChoices, id: \.key) { choice in
                            Text(choice.name).tag(String?.some(choice.key))
                        }
                    }
                } header: {
                    Text("Bowl")
                } footer: {
                    Text("Nothing is moved: the entries stay in their bowl or the Inbox. A document's date is the one on it.")
                }

                Section {
                    Text(count == 1 ? String(localized: "1 entry matches") : String(localized: "\(count) entries match"))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(draft.existing == nil ? "New Smart Filter" : "Edit Smart Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(current.isEmpty)
                        .accessibilityIdentifier("SaveSmartFilter")
                }
            }
        }
        .onAppear(perform: load)
    }

    /// Active bowls, and the one chosen even when it is archived or gone.
    private var bowlChoices: [(key: String, name: String)] {
        var list = projects.filter { !$0.isArchived }.map { (key: Projects.key($0), name: $0.name) }
        if let bowl, bowl != SmartFilterCriteria.inbox, !list.contains(where: { $0.key == bowl }) {
            list.append((key: bowl, name: bowlName(bowl) ?? String(localized: "Deleted Bowl")))
        }
        return list
    }

    private func bowlName(_ key: String) -> String? {
        projects.first { Projects.key($0) == key }?.name
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let given = draft.criteria
        name = draft.name
        text = given.text
        tags = given.tags.joined(separator: ", ")
        kind = given.kind
        source = given.source
        documentKind = given.documentKind
        sender = given.sender ?? ""
        bowl = given.bowl
        if let whole = given.wholeYear {
            dates = .year
            year = whole
        } else if given.from != nil || given.to != nil {
            dates = .custom
            hasFrom = given.from != nil
            hasTo = given.to != nil
            fromDate = DocumentInfo.date(fromDay: given.from) ?? Date()
            toDate = DocumentInfo.date(fromDay: given.to) ?? Date()
        }
    }

    private func save() {
        let current = criteria
        let store = SmartFilterStore.shared
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = typed.isEmpty ? SmartFilters.suggestedName(for: current, bowlName: bowlName) : typed
        if let existing = draft.existing {
            store.update(existing.id, name: finalName, criteria: current)
            onSave(store.filter(existing.id) ?? existing)
        } else {
            onSave(store.add(name: finalName, criteria: current))
        }
        dismiss()
    }
}
