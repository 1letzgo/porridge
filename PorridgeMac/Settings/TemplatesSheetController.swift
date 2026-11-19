import AppKit

/// The user's own meeting templates: a name and what the summary should look at. The Mac form of
/// `SummaryTemplatesView`.
final class TemplatesSheetController: NSViewController {
    private var templates = SummaryTemplate.custom
    private var list = NSStackView()
    private static let width: CGFloat = 460

    override func loadView() {
        let (scroll, stack) = SettingsSheet.scrollingStack(spacing: 10)
        list = stack
        let add = ActionButton(title: "Add Template…", symbol: "plus") { [weak self] in
            self?.edit(SummaryTemplate(id: UUID().uuidString, name: "", focus: "", sections: nil))
        }
        let done = SettingsSheet.defaultButton("Done") { [weak self] in self?.dismiss(nil) }
        let header = NSStackView.horizontal([SettingsSheet.title("Custom Templates")])
        header.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 10, right: 20)
        let page = NSStackView.vertical([header, scroll, SettingsSheet.footer(left: [add], right: [done])], spacing: 0, alignment: .leading)
        page.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            page.widthAnchor.constraint(equalToConstant: Self.width),
            page.heightAnchor.constraint(equalToConstant: 380),
        ])
        view = page
        render()
    }

    private func render() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let width = Self.width - 40
        if templates.isEmpty {
            list.addArrangedSubview(SettingsForm.footnote(
                "Your own templates tell the summary what to look at, for example “Note every price that is mentioned”.",
                width: width
            ))
        }
        for (index, template) in templates.enumerated() {
            if index > 0 { list.addArrangedSubview(SettingsSheet.hairline(width: width)) }
            list.addArrangedSubview(row(template, width: width))
        }
    }

    private func row(_ template: SummaryTemplate, width: CGFloat) -> NSView {
        let name = NSTextField.label(template.name)
        let focus = NSTextField.label(template.focus, font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, lines: 2)
        focus.preferredMaxLayoutWidth = width - 70
        let text = NSStackView.vertical([name, focus], spacing: 2)
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        let edit = NSButton.symbolButton("pencil", label: "Edit \(template.name)") { [weak self] in self?.edit(template) }
        let delete = NSButton.symbolButton("trash", label: "Delete \(template.name)", tint: .brandDangerText) { [weak self] in
            self?.confirmDelete(template)
        }
        let row = NSStackView.horizontal([text, edit, delete], spacing: 10)
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    private func edit(_ template: SummaryTemplate) {
        presentAsSheet(TemplateEditorController(template: template) { [weak self] saved in
            guard let self else { return }
            if let index = self.templates.firstIndex(where: { $0.id == saved.id }) {
                self.templates[index] = saved
            } else {
                self.templates.append(saved)
            }
            SummaryTemplate.custom = self.templates
            self.render()
        })
    }

    private func confirmDelete(_ template: SummaryTemplate) {
        Alerts.confirm("Delete \(template.name)?", message: "This cannot be undone.", action: "Delete", in: view.window) { [weak self] in
            guard let self else { return }
            self.templates.removeAll { $0.id == template.id }
            SummaryTemplate.custom = self.templates
            self.render()
        }
    }
}

/// A template's name and focus; Cancel throws the changes away, Save keeps them.
private final class TemplateEditorController: NSViewController, NSTextViewDelegate {
    private var template: SummaryTemplate
    private let onSave: (SummaryTemplate) -> Void
    private var nameField: SettingsTextField!
    private var saveButton: NSButton!

    init(template: SummaryTemplate, onSave: @escaping (SummaryTemplate) -> Void) {
        self.template = template
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        nameField = SettingsTextField(placeholder: "Name", width: 340) { [weak self] text in
            self?.template.name = text
            self?.validate()
        }
        nameField.stringValue = template.name

        let scroll = NSTextView.scrollableTextView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .bezelBorder
        if let text = scroll.documentView as? NSTextView {
            text.string = template.focus
            text.font = .systemFont(ofSize: NSFont.systemFontSize)
            text.isRichText = false
            text.allowsUndo = true
            text.delegate = self
            text.setAccessibilityLabel("What should the summary look at?")
        }
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 340),
            scroll.heightAnchor.constraint(equalToConstant: 130),
        ])

        let form = SettingsForm()
        form.grid.column(at: 0).width = 60
        form.grid.column(at: 1).width = 340
        form.row("Name", nameField)
        form.row("Focus", scroll, top: true)
        form.note("What should the summary look at?").label.preferredMaxLayoutWidth = 340

        let cancel = SettingsSheet.cancelButton { [weak self] in self?.dismiss(nil) }
        saveButton = SettingsSheet.defaultButton("Save") { [weak self] in
            guard let self else { return }
            self.onSave(self.template)
            self.dismiss(nil)
        }
        let header = NSStackView.horizontal([SettingsSheet.title("Template")])
        header.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 12, right: 20)
        let body = NSStackView.horizontal([form.grid])
        body.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        let page = NSStackView.vertical([header, body, SettingsSheet.footer(left: [cancel], right: [saveButton])], spacing: 0, alignment: .leading)
        page.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
        view = page
        validate()
    }

    func textDidChange(_ notification: Notification) {
        guard let text = notification.object as? NSTextView else { return }
        template.focus = text.string
        validate()
    }

    private func validate() {
        saveButton?.isEnabled = !template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !template.focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
