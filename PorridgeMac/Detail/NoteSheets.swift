import AppKit

/// The sheets of a note's page: choosing the model (and template) of a summary or an enhance, editing the summary,
/// merging recordings, exporting a meeting.
@MainActor
enum NoteSheets {
    static func summaryOptions(for note: Note, in controller: NSViewController) {
        let processing = Library.shared.processing
        let sheet = SummaryOptionsViewController(
            mode: note.summary != nil ? .summarizeAgain : .summarize,
            showsTemplates: !note.segments.isEmpty,
            material: !note.segments.isEmpty ? "transcript" : note.isLink ? "page" : "note"
        ) { template, model in
            guard !processing.summarizing.contains(note.id) else { return }
            let job = ProcessingService.Job.summary(note.id, template, model)
            // The editor hands its text to the note a moment after typing.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                processing.enqueue(job)
            }
        }
        controller.presentAsSheet(sheet)
    }

    static func enhanceOptions(for note: Note, in controller: NSViewController) {
        let processing = Library.shared.processing
        let sheet = SummaryOptionsViewController(mode: .enhance, showsTemplates: false, material: "note") { _, model in
            guard !processing.enhancing.contains(note.id) else { return }
            let job = ProcessingService.Job.enhance(note.id, model)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                processing.enqueue(job)
            }
        }
        controller.presentAsSheet(sheet)
    }

    static func editSummary(of note: Note, in controller: NSViewController) {
        if note.summary == nil { note.summary = "" }
        controller.presentAsSheet(SummaryEditorViewController(note: note))
    }

    static func merge(_ note: Note, in controller: NSViewController) {
        controller.presentAsSheet(MergeViewController(base: note))
    }

    static func export(_ note: Note, in controller: NSViewController) {
        controller.presentAsSheet(ExportViewController(note: note))
    }

    static func continueRecording(_ note: Note, in controller: NSViewController) {
        Capture.continueRecording(note)
    }
}

/// A sheet's frame: a bold title on top, the content, and the buttons at the bottom (Cancel left, the main one right).
class SheetViewController: NSViewController {
    let stack = NSStackView()
    let buttons = NSStackView()
    private let heading = NSTextField.label(font: .systemFont(ofSize: 17, weight: .bold))
    var width: CGFloat = 440

    override func loadView() {
        heading.stringValue = title ?? ""
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        let all = NSStackView.vertical([heading, stack, buttons], spacing: 16)
        root.addSubview(all)
        all.pinEdges(to: root, insets: NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20))
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: width),
            stack.widthAnchor.constraint(equalTo: all.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: all.widthAnchor),
        ])
        view = root
        build()
    }

    /// Fills `stack` and `buttons`.
    func build() {}

    @discardableResult
    func addCancel(_ title: String = "Cancel") -> ActionButton {
        let button = ActionButton(title: title) { [weak self] in self?.dismiss(nil) }
        button.keyEquivalent = "\u{1b}"
        buttons.addArrangedSubview(button)
        return button
    }

    func addSpacer() {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttons.addArrangedSubview(spacer)
    }

    @discardableResult
    func addDefault(_ title: String, handler: @escaping () -> Void) -> ActionButton {
        let button = ActionButton(title: title, handler: handler)
        button.keyEquivalent = "\r"
        buttons.addArrangedSubview(button)
        return button
    }

    func footnote(_ text: String, color: NSColor = .secondaryLabelColor) -> NSTextField {
        let field = NSTextField.label(text, font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: color, lines: 0)
        field.preferredMaxLayoutWidth = width - 40
        return field
    }
}

/// The model of this summary (or enhance) and, for a meeting, its template: a click on a template starts.
final class SummaryOptionsViewController: SheetViewController {
    enum Mode { case summarize, summarizeAgain, enhance }

    private let mode: Mode
    private let showsTemplates: Bool
    private let material: String
    private let onStart: (SummaryTemplate, SummaryModel) -> Void
    private let popup = NSPopUpButton()
    private let hint = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, lines: 0)
    private var models: [SummaryModel] = []

    init(mode: Mode, showsTemplates: Bool, material: String, onStart: @escaping (SummaryTemplate, SummaryModel) -> Void) {
        self.mode = mode
        self.showsTemplates = showsTemplates
        self.material = material
        self.onStart = onStart
        super.init(nibName: nil, bundle: nil)
        title = mode == .enhance ? "Enhance" : mode == .summarizeAgain ? "Summarize Again" : "Summarize"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var model: SummaryModel {
        models.indices.contains(popup.indexOfSelectedItem) ? models[popup.indexOfSelectedItem] : SummaryModel.current
    }

    override func build() {
        // The default is always there, also when it still has to download.
        models = SummaryModel.available
        if !models.contains(SummaryModel.current) { models.insert(SummaryModel.current, at: 0) }
        for model in models { popup.addItem(withTitle: model.menuTitle) }
        if let index = models.firstIndex(of: SummaryModel.current) { popup.selectItem(at: index) }
        popup.target = self
        popup.action = #selector(modelChanged)
        popup.setAccessibilityLabel("Model")
        let label = NSTextField.label("Model", font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold))
        stack.addArrangedSubview(NSStackView.horizontal([label, popup], spacing: 10))
        hint.preferredMaxLayoutWidth = width - 40
        stack.addArrangedSubview(hint)
        modelChanged()

        if showsTemplates {
            let heading = NSTextField.label("Template", font: .systemFont(ofSize: NSFont.systemFontSize, weight: .bold), color: .brandSkyText)
            stack.addArrangedSubview(heading)
            let list = NSStackView()
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 2
            for template in SummaryTemplate.all {
                let button = ActionButton(title: template.name) { [weak self] in self?.start(template) }
                button.bezelStyle = .push
                button.alignment = .left
                list.addArrangedSubview(button)
                button.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            let scroll = NSScrollView()
            let document = FlippedView()
            document.translatesAutoresizingMaskIntoConstraints = false
            list.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(list)
            list.pinEdges(to: document)
            scroll.documentView = document
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scroll.heightAnchor.constraint(equalToConstant: min(CGFloat(SummaryTemplate.all.count) * 30 + 8, 300)),
                document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            ])
        }
        if mode == .enhance {
            stack.addArrangedSubview(footnote("AI fixes mistakes, gives the note structure and marks tasks as checkboxes. Your text is replaced; Undo brings it back."))
        }
        if mode == .summarizeAgain {
            stack.addArrangedSubview(footnote("This replaces the current summary; your edits to it are lost."))
        }
        addCancel()
        addSpacer()
        if !showsTemplates {
            addDefault(mode == .enhance ? "Enhance" : mode == .summarizeAgain ? "Summarize Again" : "Summarize") { [weak self] in
                self?.start(.general)
            }
        }
    }

    @objc private func modelChanged() {
        switch model {
        case .cloud(let provider, _):
            hint.stringValue = "The \(material) goes to \(provider == .custom ? "your server" : provider.label)."
        case .local(let local):
            hint.stringValue = model.isOnHand ? "" : "The model downloads first (\(local.sizeText))."
        }
        hint.isHidden = hint.stringValue.isEmpty
    }

    private func start(_ template: SummaryTemplate) {
        let model = model
        dismiss(nil)
        onStart(template, model)
    }
}

/// The summary in the note editor; "Done" keeps it, an emptied summary is removed.
final class SummaryEditorViewController: SheetViewController {
    private let note: Note
    private var editor: NoteEditorView!

    init(note: Note) {
        self.note = note
        super.init(nibName: nil, bundle: nil)
        title = "Summary"
        width = 620
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        let note = note
        editor = NoteEditorView(get: { note.summary ?? "" }, set: { note.summary = $0 })
        editor.placeholderText = "Summary"
        stack.addArrangedSubview(editor)
        NSLayoutConstraint.activate([
            editor.widthAnchor.constraint(equalTo: stack.widthAnchor),
            editor.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])
        addSpacer()
        addDefault("Done") { [weak self] in self?.finish() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        editor.focus()
    }

    private func finish() {
        editor.stop()
        let text = (note.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            note.summary = nil
            note.summaryModel = nil
            note.summarizedAt = nil
        } else {
            note.summary = text
        }
        Library.shared.save()
        dismiss(nil)
    }
}

/// Pick the meetings to add to a meeting; they are combined into it in time order and removed.
final class MergeViewController: SheetViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let base: Note
    private var candidates: [Note] = []
    private var selection = Set<UUID>()
    private let table = NSTableView()
    private let note = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, lines: 0)
    private let warning = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, lines: 0)
    private let spinner = NSProgressIndicator()
    private var mergeButton: ActionButton!
    private var cancelButton: ActionButton!
    private var isMerging = false

    init(base: Note) {
        self.base = base
        super.init(nibName: nil, bundle: nil)
        title = "Merge Recordings"
        width = 480
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func build() {
        let processing = Library.shared.processing
        candidates = Library.shared.notes
            .filter { $0.id != base.id && !$0.isDeleted && $0.isRecording && $0.status == .ready && processing.stages[$0.id] == nil }
            .sorted { $0.createdAt > $1.createdAt }
        if candidates.isEmpty {
            let empty = EmptyMessageView()
            empty.show(title: "Nothing to Merge", message: "There are no other finished recordings.", symbol: "person.2.wave.2")
            stack.addArrangedSubview(empty)
            empty.heightAnchor.constraint(equalToConstant: 200).isActive = true
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        } else {
            let column = NSTableColumn(identifier: .init("meeting"))
            table.addTableColumn(column)
            table.headerView = nil
            table.style = .inset
            table.usesAutomaticRowHeights = true
            table.selectionHighlightStyle = .none
            table.dataSource = self
            table.delegate = self
            table.setAccessibilityLabel("Recordings")
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scroll.heightAnchor.constraint(equalToConstant: 320),
            ])
        }
        warning.preferredMaxLayoutWidth = width - 40
        note.preferredMaxLayoutWidth = width - 40
        stack.addArrangedSubview(warning)
        stack.addArrangedSubview(note)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        cancelButton = addCancel()
        addSpacer()
        buttons.addArrangedSubview(spinner)
        mergeButton = addDefault("Merge") { [weak self] in self?.merge() }
        update()
    }

    private var chosen: [Note] { candidates.filter { selection.contains($0.id) } }

    private func update() {
        let chosen = chosen
        mergeButton.isEnabled = !chosen.isEmpty && !isMerging
        mergeButton.title = chosen.isEmpty ? "Merge" : "Merge \(chosen.count + 1) Recordings"
        cancelButton.isEnabled = !isMerging
        // Without every recording on this device the audio cannot be joined and is dropped.
        let losesAudio = !chosen.isEmpty && !NextcloudSync.shared.isActive && !([base] + chosen).allSatisfy(\.hasLocalAudio)
        warning.stringValue = losesAudio ? "Some recordings are not on this device. The merged meeting will have no audio." : ""
        warning.isHidden = !losesAudio
        note.stringValue = chosen.isEmpty ? "" : "Combined in time order into “\(base.displayTitle)”. The other meetings are removed."
        note.isHidden = chosen.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let meeting = candidates[row]
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
        box.tag = row
        box.state = selection.contains(meeting.id) ? .on : .off
        box.isEnabled = !isMerging
        box.setAccessibilityLabel(meeting.displayTitle)
        let title = NSTextField.label(meeting.displayTitle, font: .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold), color: .brandNavy, lines: 2)
        let detail = NSTextField.label(
            meeting.createdAt.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()) + " · " + meeting.duration.durationText,
            font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor
        )
        let text = NSStackView.vertical([title, detail], spacing: 3)
        let line = NSStackView.horizontal([box, text], spacing: 10)
        let cell = NSTableCellView()
        cell.addSubview(line)
        line.pinEdges(to: cell, insets: NSEdgeInsets(top: 8, left: 4, bottom: 8, right: 4))
        return cell
    }

    @objc private func toggled(_ sender: NSButton) {
        let id = candidates[sender.tag].id
        if sender.state == .on { selection.insert(id) } else { selection.remove(id) }
        update()
    }

    private func merge() {
        let chosen = chosen
        guard !chosen.isEmpty else { return }
        isMerging = true
        spinner.startAnimation(nil)
        update()
        table.reloadData()
        Task { @MainActor in
            do {
                // With Nextcloud the recordings may still be there only: they come first, so the audio joins.
                if NextcloudSync.shared.isActive {
                    for name in ([base] + chosen).compactMap(\.audioFileName) where !AudioStore.exists(name) {
                        try await NextcloudSync.shared.fetchRecording(name)
                    }
                }
                try await NoteMerger.merge(chosen, into: base, context: Library.shared.context)
                Library.shared.setNeedsReload()
                dismiss(nil)
            } catch {
                isMerging = false
                spinner.stopAnimation(nil)
                update()
                table.reloadData()
                Alerts.inform("Merge Failed", message: error.localizedDescription, in: view.window)
            }
        }
    }
}

/// A meeting as a text file or a formatted PDF; summary and transcript can be chosen on their own. The file is
/// saved with the save panel or handed to a sharing service.
final class ExportViewController: SheetViewController {
    private let note: Note
    private let summary = NSButton(checkboxWithTitle: "Summary", target: nil, action: nil)
    private let transcript = NSButton(checkboxWithTitle: "Transcript", target: nil, action: nil)
    private let format = NSSegmentedControl(labels: MeetingExport.Format.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let message = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, lines: 0)
    private var saveButton: ActionButton!
    private var shareButton: ActionButton!
    private var file: URL?
    private var preparing: Task<Void, Never>?

    init(note: Note) {
        self.note = note
        super.init(nibName: nil, bundle: nil)
        title = "Export"
        width = 400
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var hasSummary: Bool { !(note.summary ?? "").isEmpty }
    private var hasTranscript: Bool { !note.segments.isEmpty }

    override func build() {
        summary.state = hasSummary ? .on : .off
        summary.isEnabled = hasSummary
        transcript.state = hasTranscript ? .on : .off
        transcript.isEnabled = hasTranscript
        format.selectedSegment = MeetingExport.Format.allCases.firstIndex(of: .pdf) ?? 0
        for control in [summary, transcript, format] as [NSControl] {
            control.target = self
            control.action = #selector(prepareFile)
        }
        format.setAccessibilityLabel("Format")
        message.preferredMaxLayoutWidth = width - 40
        stack.addArrangedSubview(summary)
        stack.addArrangedSubview(transcript)
        stack.addArrangedSubview(format)
        stack.addArrangedSubview(message)
        addCancel("Done")
        addSpacer()
        shareButton = ActionButton(title: "Share…", symbol: "square.and.arrow.up") { [weak self] in self?.share() }
        buttons.addArrangedSubview(shareButton)
        saveButton = addDefault("Save…") { [weak self] in self?.save() }
        prepareFile()
    }

    /// The file is made as soon as the choice changes, so saving and sharing have it right away.
    @objc private func prepareFile() {
        preparing?.cancel()
        file = nil
        saveButton.isEnabled = false
        shareButton.isEnabled = false
        let export = MeetingExport(note: note, includeSummary: summary.state == .on, includeTranscript: transcript.state == .on)
        guard !export.isEmpty else {
            message.stringValue = "This meeting has no summary or transcript yet."
            return
        }
        message.stringValue = ""
        let chosen = MeetingExport.Format.allCases[max(0, format.selectedSegment)]
        preparing = Task { @MainActor in
            let result = await Task.detached { try? export.write(chosen) }.value
            guard !Task.isCancelled else { return }
            file = result
            message.stringValue = result == nil ? "The file could not be written." : ""
            message.textColor = result == nil ? .brandDangerText : .secondaryLabelColor
            saveButton.isEnabled = result != nil
            shareButton.isEnabled = result != nil
        }
    }

    private func save() {
        guard let file, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.lastPathComponent
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let target = panel.url else { return }
            try? FileManager.default.removeItem(at: target)
            do {
                try FileManager.default.copyItem(at: file, to: target)
                self?.dismiss(nil)
            } catch {
                Alerts.inform("Export Failed", message: error.localizedDescription, in: self?.view.window)
            }
        }
    }

    private func share() {
        guard let file else { return }
        let picker = NSSharingServicePicker(items: [file])
        picker.show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .minY)
    }
}
