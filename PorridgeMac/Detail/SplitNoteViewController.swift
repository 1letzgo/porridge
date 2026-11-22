import AppKit

/// "Split into Bowl…": the proposal for a long note (a new bowl and the entries cut out of it), to be checked before
/// anything is made. Entries can be renamed or left out; nothing happens before "Create".
@MainActor
final class SplitNoteViewController: SheetViewController {
    private let note: Note
    private let onCreate: (BowlChange) -> Void
    private var proposal: SplitProposal
    private let nameField = NSTextField()
    private let list = NSStackView()
    private let scroll = NSScrollView()
    private let moveSource = NSButton(checkboxWithTitle: "Move this note into the bowl", target: nil, action: nil)
    private let status = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, lines: 0)
    private let spinner = NSProgressIndicator()
    private var createButton: ActionButton!
    private var isAsking = false
    private var modelFailed = false
    private var askTask: Task<Void, Never>?

    init(note: Note, onCreate: @escaping (BowlChange) -> Void) {
        self.note = note
        self.onCreate = onCreate
        proposal = NoteSplitter.structural(title: note.title, text: NoteSplitter.material(of: note))
        super.init(nibName: nil, bundle: nil)
        title = "Split into Bowl"
        width = 520
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        nameField.placeholderString = "Bowl Name"
        nameField.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
        nameField.target = self
        nameField.action = #selector(nameChanged)
        nameField.cell?.sendsActionOnEndEditing = true
        nameField.setAccessibilityLabel("Bowl Name")
        let nameLabel = NSTextField.label("Bowl", font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), color: .secondaryLabelColor)
        stack.addArrangedSubview(NSStackView.vertical([nameLabel, nameField], spacing: 4))
        nameField.widthAnchor.constraint(equalToConstant: width - 40).isActive = true

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        list.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 340),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        moveSource.state = .on
        moveSource.target = self
        moveSource.action = #selector(update)
        stack.addArrangedSubview(moveSource)
        status.preferredMaxLayoutWidth = width - 40
        stack.addArrangedSubview(status)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addCancel()
        addSpacer()
        buttons.addArrangedSubview(spinner)
        createButton = addDefault("Create") { [weak self] in self?.create() }
        showProposal()
        askModel()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        askTask?.cancel()
    }

    private func showProposal() {
        nameField.stringValue = proposal.bowlName
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let notes = proposal.entries.indices.filter { !proposal.entries[$0].isTodo }
        let todos = proposal.entries.indices.filter { proposal.entries[$0].isTodo }
        if !notes.isEmpty { list.addArrangedSubview(sectionLabel("Notes")) }
        for index in notes { list.addArrangedSubview(row(index)) }
        if !todos.isEmpty { list.addArrangedSubview(sectionLabel("To-dos")) }
        for index in todos { list.addArrangedSubview(row(index)) }
        if proposal.entries.isEmpty {
            list.addArrangedSubview(NSTextField.label("Nothing to split off. The note can still go into the new bowl.", color: .secondaryLabelColor, lines: 0))
        }
        update()
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        NSTextField.label(text, font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .bold), color: .secondaryLabelColor)
    }

    private func row(_ index: Int) -> NSView {
        let entry = proposal.entries[index]
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
        box.tag = index
        box.state = entry.isIncluded ? .on : .off
        box.setAccessibilityLabel(entry.title)
        let field = NSTextField(string: entry.title)
        field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        field.tag = index
        field.target = self
        field.action = #selector(titleChanged(_:))
        field.cell?.sendsActionOnEndEditing = true
        field.placeholderString = entry.isTodo ? "To-do" : "Title"
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [field]
        if !entry.text.isEmpty {
            let preview = NSTextField.label(NoteText.plainLines(entry.text).joined(separator: " "), font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, lines: 2)
            preview.preferredMaxLayoutWidth = width - 100
            views.append(preview)
        }
        if let due = entry.dueDay {
            views.append(NSTextField.label("Due " + Todos.dueLabel(due), font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor))
        }
        let text = NSStackView.vertical(views, spacing: 3)
        field.widthAnchor.constraint(equalToConstant: width - 100).isActive = true
        return NSStackView.horizontal([box, text], spacing: 8, alignment: .top)
    }

    @objc private func toggled(_ sender: NSButton) {
        guard proposal.entries.indices.contains(sender.tag) else { return }
        proposal.entries[sender.tag].isIncluded = sender.state == .on
        update()
    }

    @objc private func titleChanged(_ sender: NSTextField) {
        guard proposal.entries.indices.contains(sender.tag) else { return }
        proposal.entries[sender.tag].title = sender.stringValue
    }

    @objc private func nameChanged() {
        proposal.bowlName = nameField.stringValue
        update()
    }

    @objc private func update() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        createButton.isEnabled = !isAsking && !name.isEmpty && (!proposal.included.isEmpty || moveSource.state == .on)
        let count = proposal.included.count
        createButton.title = count == 0 ? "Create" : "Create \(count) " + (count == 1 ? "Entry" : "Entries")
        let exists = Library.shared.projects.contains { !$0.isArchived && !BowlSharing.shared.isReadOnly($0.id) && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        var lines: [String] = []
        if exists { lines.append("A bowl of this name exists: the entries go into it.") }
        lines.append("The note itself stays as it is.")
        if isAsking {
            lines.append("Asking the model for a better split…")
        } else if let label = proposal.modelLabel {
            lines.append("Proposed by \(label).")
        } else if modelFailed {
            lines.append("The model could not split the note; this split follows its structure.")
        } else {
            lines.append("Split by the note's headings, paragraphs and task lines.")
        }
        status.stringValue = lines.joined(separator: " ")
    }

    /// A model that can answer without a download proposes a better split; the structural one stays on failure.
    private func askModel() {
        guard let model = NoteSplitter.availableModel, NoteSplitter.material(of: note).count <= NoteSplitter.modelLimit(model) else { return }
        isAsking = true
        spinner.startAnimation(nil)
        update()
        askTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let better = try await NoteSplitter.proposeWithModel(self.note, model: model)
                guard !Task.isCancelled else { return }
                self.proposal = better
            } catch {
                self.modelFailed = true
            }
            self.isAsking = false
            self.spinner.stopAnimation(nil)
            self.showProposal()
        }
    }

    private func create() {
        // Typing in a field not yet committed counts.
        view.window?.makeFirstResponder(nil)
        proposal.bowlName = nameField.stringValue
        guard let change = NoteSplitter.apply(proposal, from: note, moveSource: moveSource.state == .on, in: Library.shared.context) else { return }
        onCreate(change)
        dismiss(nil)
    }
}
