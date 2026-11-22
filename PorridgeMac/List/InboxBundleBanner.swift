import AppKit

/// On top of the Inbox: one suggestion to put entries that belong together into a new bowl (`InboxBundler`), or,
/// right after that was done, the way to take it back.
@MainActor
final class InboxBundleBanner: NSView {
    private let panel = PanelView()
    private let close = NSButton()
    private var bundle: InboxBundle?
    private var lastChange: BowlChange?
    private var pending: Task<Void, Never>?
    private var lastSignature = ""
    weak var host: NSViewController?
    /// Hidden, the banner takes no room: its content's constraints give way to a height of zero.
    private var contentConstraints: [NSLayoutConstraint] = []
    private lazy var collapsed = heightAnchor.constraint(equalToConstant: 0)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss Suggestion")
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.target = self
        close.action = #selector(closeTapped)
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        addSubview(close)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            panel.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -6),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            close.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
        ])
        contentConstraints = [
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ]
        setShown(false)
    }

    private func setShown(_ shown: Bool) {
        isHidden = !shown
        if shown {
            collapsed.isActive = false
            NSLayoutConstraint.activate(contentConstraints)
        } else {
            NSLayoutConstraint.deactivate(contentConstraints)
            collapsed.isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The inbox may have changed: the suggestion is looked for again once things rest.
    func refresh(isInbox: Bool) {
        guard isInbox else {
            pending?.cancel()
            bundle = nil
            lastChange = nil
            render()
            return
        }
        let library = Library.shared
        let signature = library.notes.filter(\.isInInbox).map { "\($0.id)\($0.suggestedProjectIDs.count)\($0.labels.count)" }.joined()
            + "|\(NoteIndex.shared.version)"
        guard signature != lastSignature else { return }
        lastSignature = signature
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            let next = InboxBundler.current(library.notes, projects: library.projects)
            if next != self.bundle {
                self.bundle = next
                self.render()
            }
        }
    }

    private func render() {
        if let lastChange {
            setShown(true)
            panel.show(symbol: "folder.badge.plus", text: lastChange.summary, tint: .brandProject, action: ("Undo", { [weak self] in self?.undo() }))
        } else if let bundle {
            setShown(true)
            let text = bundle.isExistingBowl
                ? "These \(bundle.noteIDs.count) entries belong together. Into bowl “\(bundle.name)”?"
                : "These \(bundle.noteIDs.count) entries belong together. New bowl “\(bundle.name)”?"
            let titles = bundle.noteIDs.compactMap { Library.shared.note($0)?.displayTitle }.joined(separator: " · ")
            panel.show(symbol: "sparkles", text: text, detail: titles, tint: .brandProject, action: ("Review…", { [weak self] in self?.openReview() }))
        } else {
            setShown(false)
        }
    }

    @objc private func closeTapped() {
        if lastChange != nil {
            lastChange = nil
        } else if let bundle {
            InboxBundler.dismiss(bundle)
            self.bundle = nil
        }
        render()
    }

    private func openReview() {
        guard let bundle, let host else { return }
        host.presentAsSheet(InboxBundleViewController(bundle: bundle) { [weak self] change in
            guard let self else { return }
            self.lastChange = change
            self.bundle = nil
            Library.shared.setNeedsReload()
            self.render()
            // The way back is offered for a while only.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: BowlMaking.undoLifetime)
                guard let self, self.lastChange?.madeAt == change.madeAt else { return }
                self.lastChange = nil
                self.render()
            }
        })
    }

    private func undo() {
        guard let change = lastChange else { return }
        lastChange = nil
        BowlMaking.undo(change, in: Library.shared.context)
        Library.shared.setNeedsReload()
        render()
    }
}

/// The entries of a suggested bundle, each with a checkbox, and the bowl's name; "Create" makes the bowl and moves the
/// chosen entries into it.
@MainActor
final class InboxBundleViewController: SheetViewController {
    private let bundle: InboxBundle
    private let onCreate: (BowlChange) -> Void
    private let nameField = NSTextField()
    private var chosen: Set<UUID>
    private var createButton: ActionButton!

    init(bundle: InboxBundle, onCreate: @escaping (BowlChange) -> Void) {
        self.bundle = bundle
        self.onCreate = onCreate
        chosen = Set(bundle.noteIDs)
        super.init(nibName: nil, bundle: nil)
        title = bundle.isExistingBowl ? "Into Bowl" : "New Bowl"
        width = 460
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        nameField.stringValue = bundle.name
        nameField.placeholderString = "Bowl Name"
        nameField.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
        nameField.setAccessibilityLabel("Bowl Name")
        nameField.target = self
        nameField.action = #selector(update)
        nameField.cell?.sendsActionOnEndEditing = true
        stack.addArrangedSubview(nameField)
        nameField.widthAnchor.constraint(equalToConstant: width - 40).isActive = true

        for (index, id) in bundle.noteIDs.enumerated() {
            guard let note = Library.shared.note(id) else { continue }
            let box = NSButton(checkboxWithTitle: note.displayTitle, target: self, action: #selector(toggled(_:)))
            box.tag = index
            box.state = .on
            box.lineBreakMode = .byTruncatingTail
            box.widthAnchor.constraint(lessThanOrEqualToConstant: width - 40).isActive = true
            stack.addArrangedSubview(box)
        }
        stack.addArrangedSubview(footnote("The chosen entries leave the Inbox and go into the bowl. Nothing else changes."))

        addCancel()
        addSpacer()
        createButton = addDefault("Create") { [weak self] in self?.create() }
        update()
    }

    @objc private func toggled(_ sender: NSButton) {
        guard bundle.noteIDs.indices.contains(sender.tag) else { return }
        let id = bundle.noteIDs[sender.tag]
        if sender.state == .on { chosen.insert(id) } else { chosen.remove(id) }
        update()
    }

    @objc private func update() {
        createButton?.isEnabled = !chosen.isEmpty && !nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create() {
        view.window?.makeFirstResponder(nil)
        let ids = bundle.noteIDs.filter { chosen.contains($0) }
        guard let change = InboxBundler.apply(name: nameField.stringValue, noteIDs: ids, notes: Library.shared.notes, in: Library.shared.context) else { return }
        onCreate(change)
        dismiss(nil)
    }
}
