import AppKit

// Note templates on the Mac: "New from Template" (the New menu, the command bar), "Save as Template…", the sheet in
// Settings that lists them and the editor of one. Not the summary templates of meetings (`TemplatesSheetController`).

extension MainWindowController {
    /// A note or to-do made from the template and opened. A template that uses `{{title}}` asks for it first.
    func newFromTemplate(_ template: NoteTemplate) {
        guard template.needsTitle else {
            makeFromTemplate(template, title: "")
            return
        }
        Alerts.ask(template.name, message: String(localized: "What is it about?"), placeholder: String(localized: "Title"), action: String(localized: "Create"), in: window) { [weak self] title in
            self?.makeFromTemplate(template, title: title)
        }
    }

    private func makeFromTemplate(_ template: NoteTemplate, title: String) {
        let note = NoteTemplates.create(from: template, title: title, fallbackBowl: state.projectForNew, in: Library.shared.context)
        if state.page == .todos, note.isTodo, note.isInInbox {
            state.selection = [note.id]
        } else {
            state.reveal(note)
        }
    }
}

/// The submenu "New from Template": filled each time it opens, so it always lists the templates there are now.
@MainActor
final class NoteTemplateMenu: NSObject, NSMenuDelegate {
    private weak var controller: MainWindowController?

    private init(controller: MainWindowController) {
        self.controller = controller
    }

    /// The menu keeps its delegate weakly: the item holds it.
    private static var delegates: [ObjectIdentifier: NoteTemplateMenu] = [:]

    /// The "New from Template" item with its submenu, for the New menu of a window.
    static func item(for controller: MainWindowController) -> NSMenuItem {
        let item = NSMenuItem(title: String(localized: "New from Template"), action: nil, keyEquivalent: "")
        item.image = NSImage.symbol("doc.on.doc", size: 13, weight: .medium).tinted(NSColor.brandNavy.readable)
        let menu = NSMenu()
        let delegate = NoteTemplateMenu(controller: controller)
        menu.delegate = delegate
        delegates[ObjectIdentifier(menu)] = delegate
        item.submenu = menu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for template in NoteTemplateStore.shared.templates {
            menu.add(template.name, symbol: template.kind.symbol) { [weak controller] in controller?.newFromTemplate(template) }
        }
        if !NoteTemplateStore.shared.templates.isEmpty { menu.addSeparator() }
        menu.add(String(localized: "Edit Templates…"), symbol: "slider.horizontal.3") {
            NoteTemplateActions.showManager()
        }
    }
}

@MainActor
enum NoteTemplateActions {
    /// "Save as Template…": the editor with a template made from the entry; Save keeps it.
    static func saveAsTemplate(_ note: Note, in window: NSWindow?) {
        present(NoteTemplateEditorController(template: NoteTemplates.draft(from: note), isNew: true), in: window)
    }

    /// Settings › General › Note Templates, as a window of its own when no Settings window is open.
    static func showManager() {
        present(NoteTemplatesSheetController(), in: NSApp.keyWindow)
    }

    static func present(_ controller: NSViewController, in window: NSWindow?) {
        if let host = window?.contentViewController {
            host.presentAsSheet(controller)
        } else {
            NSWindow(contentViewController: controller).makeKeyAndOrderFront(nil)
        }
    }

    /// The submenu of the editor's "+": each template's text at the cursor.
    static func insertMenu(enabled: Bool, insert: @escaping (NoteTemplate) -> Void) -> NSMenuItem? {
        let templates = NoteTemplateStore.shared.templates
        guard !templates.isEmpty else { return nil }
        let item = NSMenuItem(title: String(localized: "Insert Template"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        let menu = NSMenu()
        for template in templates {
            menu.add(template.name, symbol: template.kind.symbol, enabled: enabled) { insert(template) }
        }
        item.submenu = menu
        return item
    }

    static func bowlName(_ key: String) -> String? {
        Library.shared.project(key: key)?.name
    }
}

// MARK: - The list

/// All note templates: edit, duplicate, delete (with Undo), and a new one.
final class NoteTemplatesSheetController: NSViewController {
    private var list = NSStackView()
    private var observing: Observing?
    private static let width: CGFloat = 500

    override func loadView() {
        let (scroll, stack) = SettingsSheet.scrollingStack(spacing: 10)
        list = stack
        let add = ActionButton(title: String(localized: "New Template…"), symbol: "plus") { [weak self] in
            self?.edit(NoteTemplate(name: ""), isNew: true)
        }
        let done = SettingsSheet.defaultButton(String(localized: "Done")) { [weak self] in self?.close() }
        let header = NSStackView.horizontal([SettingsSheet.title(String(localized: "Note Templates"))])
        header.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 10, right: 20)
        let page = NSStackView.vertical([header, scroll, SettingsSheet.footer(left: [add], right: [done])], spacing: 0, alignment: .leading)
        page.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            page.widthAnchor.constraint(equalToConstant: Self.width),
            page.heightAnchor.constraint(equalToConstant: 420),
        ])
        view = page
        observing = Observing { [weak self] in
            _ = NoteTemplateStore.shared.templates
            self?.render()
        }
    }

    private func close() {
        if presentingViewController != nil { dismiss(nil) } else { view.window?.close() }
    }

    private func render() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let width = Self.width - 40
        let templates = NoteTemplateStore.shared.templates
        if templates.isEmpty {
            list.addArrangedSubview(SettingsForm.footnote(
                String(localized: "A template starts a note or a to-do with your headings, checklists and tables. Make one with “New Template…”."),
                width: width
            ))
        }
        for (index, template) in templates.enumerated() {
            if index > 0 { list.addArrangedSubview(SettingsSheet.hairline(width: width)) }
            list.addArrangedSubview(row(template, width: width))
        }
    }

    private func row(_ template: NoteTemplate, width: CGFloat) -> NSView {
        let icon = KindIconView(side: 30)
        icon.symbol = template.kind.symbol
        icon.tint = template.isTodo ? .brandTask : .brandSky
        let name = NSTextField.label(template.name)
        let summary = NSTextField.label(
            NoteTemplates.summary(of: template, bowlName: NoteTemplateActions.bowlName),
            font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor
        )
        summary.lineBreakMode = .byTruncatingTail
        let text = NSStackView.vertical([name, summary], spacing: 2)
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        text.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let edit = NSButton.symbolButton("pencil", label: String(localized: "Edit \(template.name)")) { [weak self] in
            self?.edit(template, isNew: false)
        }
        let duplicate = NSButton.symbolButton("plus.square.on.square", label: String(localized: "Duplicate \(template.name)")) {
            NoteTemplateStore.shared.duplicate(template.id)
        }
        let delete = NSButton.symbolButton("trash", label: String(localized: "Delete \(template.name)"), tint: .brandDangerText) {
            Self.delete(template)
        }
        let row = NSStackView.horizontal([icon, text, edit, duplicate, delete], spacing: 10)
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    private func edit(_ template: NoteTemplate, isNew: Bool) {
        presentAsSheet(NoteTemplateEditorController(template: template, isNew: isNew))
    }

    /// Gone at once; the undo toast (and ⌘Z in the main window) brings it back.
    private static func delete(_ template: NoteTemplate) {
        guard let gone = NoteTemplateStore.shared.delete(template.id) else { return }
        UndoToast.shared.offer(String(localized: "Deleted “\(gone.name)”"), systemImage: "trash") {
            NoteTemplateStore.shared.add(gone)
        }
    }
}

// MARK: - Editing

/// A template's name, kind, title and text; for a to-do its subtasks, due day and repeat rule; the bowl. Cancel
/// throws the changes away, Save keeps them.
final class NoteTemplateEditorController: NSViewController, NSTextViewDelegate {
    private var template: NoteTemplate
    private let isNew: Bool
    private var saveButton: NSButton!
    private var bodyView: NSTextView!
    private var subtasksView: NSTextView!
    private var todoRows: [NSGridRow] = []
    private var bowlKeys: [String?] = []
    private static let fieldWidth: CGFloat = 380

    init(template: NoteTemplate, isNew: Bool) {
        self.template = template
        self.isNew = isNew
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let width = Self.fieldWidth
        let nameField = SettingsTextField(placeholder: String(localized: "Name"), width: width) { [weak self] text in
            self?.template.name = text
            self?.validate()
        }
        nameField.stringValue = template.name
        nameField.setAccessibilityIdentifier("NoteTemplateName")

        let kind = NSSegmentedControl(
            labels: NoteTemplate.Kind.allCases.map(\.title), trackingMode: .selectOne, target: self, action: #selector(kindChanged(_:))
        )
        kind.selectedSegment = NoteTemplate.Kind.allCases.firstIndex(of: template.kind) ?? 0

        let titleField = SettingsTextField(placeholder: String(localized: "Title, e.g. {{title}} · {{date}}"), width: width) { [weak self] text in
            self?.template.title = text
        }
        titleField.stringValue = template.title

        let (bodyScroll, body) = Self.textArea(template.body, height: 170, label: String(localized: "Text"))
        body.delegate = self
        bodyView = body
        let (subtasksScroll, subtasks) = Self.textArea(template.subtasks.joined(separator: "\n"), height: 80, label: String(localized: "Subtasks"))
        subtasks.delegate = self
        subtasksView = subtasks

        let due = SettingsPopUp { [weak self] index in
            self?.template.dueOffset = NoteTemplates.dueOffsets[index]
        }
        due.set(NoteTemplates.dueOffsets.map(NoteTemplates.dueTitle), selected: NoteTemplates.dueOffsets.firstIndex(of: template.dueOffset) ?? 0)
        let repeats = SettingsPopUp { [weak self] index in
            self?.template.repeatRule = NoteTemplates.repeatChoices[index]
        }
        let ruleIndex = NoteTemplates.repeatChoices.firstIndex { choice in
            choice.flatMap(TodoRepeat.init(raw:))?.sameRule(as: template.repeats) ?? (template.repeats == nil)
        }
        repeats.set(NoteTemplates.repeatChoices.map(NoteTemplates.repeatTitle), selected: ruleIndex ?? 0)

        // The Inbox, the active bowls I may write to, and the one chosen even when it is gone.
        var bowls: [(key: String?, name: String)] = [(nil, String(localized: "Inbox"))]
        bowls += Library.shared.activeProjects.filter { !BowlSharing.shared.isReadOnly($0.id) }.map { (Projects.key($0), $0.name) }
        if let bowl = template.bowl, !bowls.contains(where: { $0.key == bowl }) {
            bowls.append((bowl, NoteTemplateActions.bowlName(bowl) ?? String(localized: "Deleted Bowl")))
        }
        bowlKeys = bowls.map(\.key)
        let bowl = SettingsPopUp { [weak self] index in
            guard let self, index >= 0, index < self.bowlKeys.count else { return }
            self.template.bowl = self.bowlKeys[index]
        }
        bowl.set(bowls.map(\.name), selected: bowlKeys.firstIndex(of: template.bowl) ?? 0)

        let form = SettingsForm()
        form.grid.column(at: 0).width = 80
        form.grid.column(at: 1).width = width
        form.row(String(localized: "Name"), nameField)
        form.row(String(localized: "Kind"), kind)
        form.separator()
        form.row(String(localized: "Title"), titleField)
        form.row(String(localized: "Text"), bodyScroll, top: true)
        let help = form.note(String(localized: "Placeholders: \(NoteTemplates.placeholderHelp). {{title}} is asked for when the entry is made."))
        help.label.preferredMaxLayoutWidth = width
        todoRows = [
            form.separator(),
            form.row(String(localized: "Subtasks"), subtasksScroll, top: true),
            form.note(String(localized: "One per line.")).row,
            form.row(String(localized: "Due"), due),
            form.row(String(localized: "Repeat"), repeats),
        ]
        form.separator()
        form.row(String(localized: "Bowl"), bowl)
        form.note(String(localized: "Without a bowl the entry goes into the bowl you are in, or the Inbox.")).label.preferredMaxLayoutWidth = width

        let cancel = SettingsSheet.cancelButton { [weak self] in self?.dismiss(nil) }
        saveButton = SettingsSheet.defaultButton(String(localized: "Save")) { [weak self] in self?.save() }
        let header = NSStackView.horizontal([SettingsSheet.title(isNew ? String(localized: "New Template") : String(localized: "Edit Template"))])
        header.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 12, right: 20)
        let body2 = NSStackView.horizontal([form.grid])
        body2.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        let page = NSStackView.vertical([header, body2, SettingsSheet.footer(left: [cancel], right: [saveButton])], spacing: 0, alignment: .leading)
        page.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
        view = page
        showTodoRows()
        validate()
    }

    private static func textArea(_ text: String, height: CGFloat, label: String) -> (NSScrollView, NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .bezelBorder
        let view = scroll.documentView as! NSTextView
        view.string = text
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.textContainerInset = NSSize(width: 2, height: 4)
        view.setAccessibilityLabel(label)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: fieldWidth),
            scroll.heightAnchor.constraint(equalToConstant: height),
        ])
        return (scroll, view)
    }

    @objc private func kindChanged(_ sender: NSSegmentedControl) {
        let kinds = NoteTemplate.Kind.allCases
        guard sender.selectedSegment >= 0, sender.selectedSegment < kinds.count else { return }
        template.kind = kinds[sender.selectedSegment]
        showTodoRows()
    }

    private func showTodoRows() {
        todoRows.forEach { $0.isHidden = !template.isTodo }
    }

    func textDidChange(_ notification: Notification) {
        guard let text = notification.object as? NSTextView else { return }
        if text === bodyView { template.body = text.string }
    }

    private func validate() {
        saveButton?.isEnabled = !template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        var saved = template
        saved.body = bodyView.string
        saved.subtasks = saved.isTodo
            ? subtasksView.string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            : []
        if !saved.isTodo {
            saved.dueOffset = nil
            saved.repeatRule = nil
        }
        let store = NoteTemplateStore.shared
        if isNew || store.template(saved.id) == nil { store.add(saved) } else { store.update(saved) }
        dismiss(nil)
    }
}
