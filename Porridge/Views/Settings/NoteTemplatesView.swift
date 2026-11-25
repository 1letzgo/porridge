import SwiftData
import SwiftUI

// Note templates (iOS): the card in Settings, the list to manage them, the editor, and the picker of
// "New from Template". Not the summary templates of meetings (`SummaryTemplatesView`).

/// The card in Settings › General: how many templates there are, and the way to the list.
struct NoteTemplatesCard: View {
    @State private var showList = false
    private var store: NoteTemplateStore { .shared }

    var body: some View {
        SettingsCard(title: "Note Templates") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Note Templates").font(.body)
                    Text(countText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button("Edit") { showList = true }
                    .buttonStyle(PillButtonStyle())
                    .accessibilityIdentifier("EditNoteTemplates")
            }
            Text("Start notes and to-dos from a template with “+”, or insert one into a note.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showList) { NoteTemplatesView() }
    }

    private var countText: String {
        let count = store.templates.count
        return count == 1 ? String(localized: "1 template") : String(localized: "\(count) templates")
    }
}

// MARK: - The list

/// All note templates: tap to edit, swipe or hold for duplicate and delete, "+" for a new one.
struct NoteTemplatesView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \NoteFolder.name) private var projects: [NoteFolder]
    @State private var editing: NoteTemplateDraft?
    @State private var renaming: NoteTemplate?
    @State private var newName = ""
    private var store: NoteTemplateStore { .shared }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.templates) { template in
                        row(template)
                            .lastInSection(template.id == store.templates.last?.id)
                    }
                } header: {
                    ListHeader(title: String(localized: "Note Templates"), count: store.templates.count, tint: .brandNavy, isFirst: true)
                }
            }
            .cardList()
            .overlay {
                if store.templates.isEmpty {
                    EmptyStateView(
                        title: "No Templates",
                        message: "A template starts a note or a to-do with your headings, checklists and tables. Tap + to make one."
                    )
                }
            }
            .overlay(alignment: .bottom) {
                // The sheet covers the app's toast: deleting here shows it here.
                UndoToastView().padding(.bottom, 16)
            }
            .navigationTitle("Note Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = .new(NoteTemplate(name: "")) } label: {
                        Label("New Template", systemImage: "plus")
                    }
                    .accessibilityIdentifier("AddNoteTemplate")
                }
            }
            .sheet(item: $editing) { draft in
                NoteTemplateEditor(draft: draft)
            }
            .alert("Rename Template", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    if let renaming { store.rename(renaming.id, to: newName) }
                }
            }
        }
        // A sheet: its empty view centers in the sheet, whatever page opened it.
        .emptyStateSheet()
    }

    private func row(_ template: NoteTemplate) -> some View {
        Button { editing = .edit(template) } label: {
            NoteTemplateRow(template: template, bowlName: bowlName)
        }
        .buttonStyle(.plain)
        .cardListRow()
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { delete(template) } label: { Label("Delete", systemImage: "trash") }
            Button { store.duplicate(template.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .tint(.brandNavy)
        }
        .contextMenu {
            Button { editing = .edit(template) } label: { Label("Edit…", systemImage: "slider.horizontal.3") }
            Button {
                newName = template.name
                renaming = template
            } label: { Label("Rename", systemImage: "pencil") }
            Button { store.duplicate(template.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Divider()
            Button(role: .destructive) { delete(template) } label: { Label("Delete", systemImage: "trash") }
        }
        .accessibilityIdentifier("NoteTemplate-\(template.name)")
    }

    private func delete(_ template: NoteTemplate) {
        guard let gone = store.delete(template.id) else { return }
        UndoToast.shared.offer(String(localized: "Deleted “\(gone.name)”"), systemImage: "trash") {
            NoteTemplateStore.shared.add(gone)
        }
    }

    private func bowlName(_ key: String) -> String? {
        projects.first { Projects.key($0) == key }?.name
    }
}

/// A template in a list: the kind as the row icon, the name, what it makes.
struct NoteTemplateRow: View {
    let template: NoteTemplate
    var bowlName: (String) -> String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ThingsRowIcon(systemImage: template.kind.symbol, tint: template.isTodo ? .brandTask : .brandSky)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(template.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(NoteTemplates.summary(of: template, bowlName: bowlName))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Editing

/// What the editor works on: a new template (empty, or from an entry) or one that exists.
struct NoteTemplateDraft: Identifiable {
    let id = UUID()
    var template: NoteTemplate
    var isNew: Bool

    static func new(_ template: NoteTemplate) -> NoteTemplateDraft { NoteTemplateDraft(template: template, isNew: true) }
    static func edit(_ template: NoteTemplate) -> NoteTemplateDraft { NoteTemplateDraft(template: template, isNew: false) }
}

/// A template's name, kind, title and text, and for a to-do its subtasks, due day and repeat rule; the bowl the
/// entry goes into. Cancel throws the changes away, Save keeps them.
struct NoteTemplateEditor: View {
    let draft: NoteTemplateDraft

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \NoteFolder.name) private var projects: [NoteFolder]
    @State private var template = NoteTemplate(name: "")
    @State private var subtasks = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    SettingsCard(title: "Template") {
                        TextField("Name", text: $template.name)
                            .brandField()
                            .accessibilityIdentifier("NoteTemplateName")
                        TabSwitcher(
                            selection: $template.kind,
                            options: NoteTemplate.Kind.allCases.map { (value: $0, title: $0.title) }
                        )
                    }
                    SettingsCard(title: "New Entry") {
                        TextField("Title", text: $template.title, prompt: Text("Title, e.g. {{title}} · {{date}}"))
                            .autocorrectionDisabled()
                            .brandField()
                            .accessibilityIdentifier("NoteTemplateTitle")
                        textArea($template.body, placeholder: "Text in Markdown: # Heading, - [ ] Checklist, tables…")
                            .accessibilityIdentifier("NoteTemplateBody")
                        Text("Placeholders: \(NoteTemplates.placeholderHelp). {{title}} is asked for when the entry is made.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if template.isTodo {
                        SettingsCard(title: "To-do") {
                            textArea($subtasks, placeholder: "Subtasks, one per line", minHeight: 90)
                                .accessibilityIdentifier("NoteTemplateSubtasks")
                            CardDivider()
                            MenuRow(
                                title: "Due",
                                selection: $template.dueOffset,
                                options: NoteTemplates.dueOffsets.map { (value: $0, title: NoteTemplates.dueTitle($0)) }
                            )
                            CardDivider()
                            MenuRow(
                                title: "Repeat",
                                selection: $template.repeatRule,
                                options: NoteTemplates.repeatChoices.map { (value: $0, title: NoteTemplates.repeatTitle($0)) }
                            )
                        }
                        .transition(.opacity)
                    }
                    SettingsCard(title: "Bowl") {
                        MenuRow(title: "Goes Into", selection: $template.bowl, options: bowlChoices)
                        Text("Without a bowl the entry goes into the bowl you are in, or the Inbox.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
                .animation(.snappy, value: template.isTodo)
            }
            .background(Color.appBackground)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(draft.isNew ? "New Template" : "Edit Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("SaveNoteTemplate")
                }
            }
        }
        .onAppear(perform: load)
    }

    private func textArea(_ text: Binding<String>, placeholder: String, minHeight: CGFloat = 160) -> some View {
        TextEditor(text: text)
            .font(.body.monospaced())
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Color.appSecondaryBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The Inbox, the active bowls I may write to, and the one chosen even when it is gone.
    private var bowlChoices: [(value: String?, title: String)] {
        var list: [(value: String?, title: String)] = [(nil, String(localized: "Inbox"))]
        list += projects.filter { !$0.isArchived && !BowlSharing.shared.isReadOnly($0.id) }.map { (Projects.key($0), $0.name) }
        if let bowl = template.bowl, !list.contains(where: { $0.value == bowl }) {
            list.append((bowl, projects.first { Projects.key($0) == bowl }?.name ?? String(localized: "Deleted Bowl")))
        }
        return list
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        template = draft.template
        subtasks = draft.template.subtasks.joined(separator: "\n")
    }

    private func save() {
        var saved = template
        saved.subtasks = saved.isTodo
            ? subtasks.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : []
        if !saved.isTodo {
            saved.dueOffset = nil
            saved.repeatRule = nil
        }
        let store = NoteTemplateStore.shared
        if draft.isNew || store.template(saved.id) == nil { store.add(saved) } else { store.update(saved) }
        dismiss()
    }
}

// MARK: - New from Template

/// "New from Template": the templates to pick from; one that uses `{{title}}` asks for it first.
struct NoteTemplatePicker: View {
    /// The template picked and the title typed for it.
    var onPick: (NoteTemplate, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \NoteFolder.name) private var projects: [NoteFolder]
    @State private var asking: NoteTemplate?
    @State private var title = ""
    @State private var showManage = false
    private var store: NoteTemplateStore { .shared }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.templates) { template in
                        Button { pick(template) } label: {
                            NoteTemplateRow(template: template, bowlName: bowlName)
                        }
                        .buttonStyle(.plain)
                        .cardListRow()
                        .lastInSection(template.id == store.templates.last?.id)
                        .accessibilityIdentifier("PickTemplate-\(template.name)")
                    }
                } header: {
                    ListHeader(title: String(localized: "Templates"), tint: .brandNavy, isFirst: true)
                }
            }
            .cardList()
            .overlay {
                if store.templates.isEmpty {
                    EmptyStateView(title: "No Templates", message: "Make one in Settings › General › Note Templates.")
                }
            }
            .navigationTitle("New from Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showManage = true } label: { Label("Edit Templates", systemImage: "slider.horizontal.3") }
                }
            }
            .sheet(isPresented: $showManage) { NoteTemplatesView() }
            .alert(asking?.name ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
                TextField("Title", text: $title)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    if let asking { finish(asking, title: title) }
                }
            } message: {
                Text("What is it about?")
            }
        }
        // A sheet: its empty view centers in the sheet, whatever page opened it.
        .emptyStateSheet()
        .presentationDetents([.medium, .large])
    }

    private func pick(_ template: NoteTemplate) {
        if template.needsTitle {
            title = ""
            asking = template
        } else {
            finish(template, title: "")
        }
    }

    private func finish(_ template: NoteTemplate, title: String) {
        dismiss()
        onPick(template, title)
    }

    private func bowlName(_ key: String) -> String? {
        projects.first { Projects.key($0) == key }?.name
    }
}
