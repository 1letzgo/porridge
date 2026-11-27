import AppKit

/// "Bring Reminders into Porridge?" on the Mac: what the first import from Reminders would bring, each list with its
/// checkbox (on at first), Not Now and Import. Put up by `AppDelegate` when `ReminderSync.isAskingImport`, as a sheet
/// of the front window (or a window of its own).
final class ReminderImportSheetController: NSViewController {
    private let preview: ReminderImportPreview
    private var selected: Set<String>
    private let summary = SettingsForm.footnote("", color: .labelColor, width: 420)
    private let inboxNote = SettingsForm.footnote(
        String(localized: "With the default list off, only reminders added there from now on come into the Inbox."), width: 420
    )
    private var answered = false

    /// The sheet that is up, so it is put up only once.
    private static weak var current: ReminderImportSheetController?

    init(preview: ReminderImportPreview) {
        self.preview = preview
        selected = Set(preview.entries.map(\.listID))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Puts the question up once (no-op while it is up).
    static func present() {
        guard current == nil, let preview = ReminderSync.shared.preview else { return }
        let controller = ReminderImportSheetController(preview: preview)
        current = controller
        // The window in front (Settings, when "Review" was clicked there), else the main window.
        let host = [NSApp.keyWindow, MainWindowController.frontIfAny?.window].compactMap { $0 }
            .first { $0.attachedSheet == nil && $0.contentViewController != nil && !($0 is NSPanel) }
        if let window = host, let content = window.contentViewController {
            content.presentAsSheet(controller)
        } else {
            let window = NSWindow(contentViewController: controller)
            window.title = String(localized: "Reminders")
            window.makeKeyAndOrderFront(nil)
        }
    }

    override func loadView() {
        summary.font = .systemFont(ofSize: NSFont.systemFontSize)
        let (scroll, stack) = SettingsSheet.scrollingStack(spacing: 8)
        for entry in preview.entries {
            let box = SettingsCheckbox(entry.title) { [weak self] on in
                guard let self else { return }
                if on { selected.insert(entry.listID) } else { selected.remove(entry.listID) }
                update()
            }
            box.isOn = true
            let detail = SettingsForm.footnote(ReminderImportPreview.detail(entry), width: 400)
            let item = NSStackView.vertical([box, detail], spacing: 2)
            item.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 4, right: 0)
            stack.addArrangedSubview(item)
        }
        let header = NSStackView.vertical([
            SettingsSheet.title(String(localized: "Bring Reminders into Porridge?")),
            summary,
            inboxNote,
            SettingsForm.footnote(
                String(localized: "Afterwards new lists and reminders come in by themselves. You can change this for each list in Settings › General."),
                width: 420
            ),
        ], spacing: 8)
        header.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 10, right: 20)
        let notNow = SettingsSheet.cancelButton(String(localized: "Not Now")) { [weak self] in
            self?.answered = true
            ReminderSync.shared.declineImport()
            self?.close()
        }
        let importButton = SettingsSheet.defaultButton(String(localized: "Import")) { [weak self] in
            guard let self else { return }
            answered = true
            ReminderSync.shared.confirmImport(leavingOut: Set(preview.entries.map(\.listID)).subtracting(selected))
            close()
        }
        let page = NSStackView.vertical([header, scroll, SettingsSheet.footer(right: [notNow, importButton])], spacing: 0, alignment: .leading)
        page.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            page.widthAnchor.constraint(equalToConstant: 460),
            page.heightAnchor.constraint(equalToConstant: min(560, 230 + CGFloat(preview.entries.count) * 46)),
        ])
        view = page
        update()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        // Closed another way: the same as Not Now.
        if !answered { ReminderSync.shared.declineImport() }
    }

    private func update() {
        summary.stringValue = preview.summary(selected: selected)
        inboxNote.isHidden = !preview.entries.contains { $0.kind == .inbox && !selected.contains($0.listID) }
    }

    private func close() {
        if presentingViewController != nil {
            dismiss(nil)
        } else {
            view.window?.close()
        }
    }
}
