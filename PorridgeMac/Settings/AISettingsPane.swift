import AppKit

/// AI: the summary models, on-device and cloud alike in one list with one default, and the custom templates.
final class AISettingsPane: SettingsPane {
    private let models = ModelManager.shared
    private let failures = FailureWatch()

    private lazy var defaultPopUp = SettingsPopUp { [weak self] index in
        let available = SummaryModel.available
        guard index >= 0, index < available.count else { return }
        SummaryModel.current = available[index]
        self?.render()
    }
    private let noneLabel = NSTextField.label("None added", color: .secondaryLabelColor)
    /// "Same as Default", then the models of the list: the chat may answer with another model than the summaries.
    private lazy var chatPopUp = SettingsPopUp { [weak self] index in
        let available = SummaryModel.available
        SummaryModel.chatChoice = index > 0 && index <= available.count ? available[index - 1] : nil
        self?.render()
    }
    private let chatHint = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, lines: 0)
    private var chatRows: [NSGridRow] = []
    private lazy var summarizeIncoming = SettingsCheckbox("Summarize Incoming Entries") { on in
        UserDefaults.standard.set(on, forKey: AppSettings.summarizeIncomingKey)
        if on { Library.shared.processing.summarizeIncoming() }
    }
    private var popUpRow: NSGridRow?
    private var noneRow: NSGridRow?
    private let list = NSStackView.vertical([], spacing: 12)
    private var rows: [String: ModelStateRow] = [:]
    /// nil until the list is first drawn, so an empty list also gets its footnote.
    private var listIDs: [String]?
    private var lastLLM: [LocalModel: ModelManager.State] = [:]

    override func build() {
        popUpRow = form.row("Default Model", defaultPopUp)
        noneRow = form.row("Default Model", noneLabel)
        chatRows = [form.row("Chat Model", chatPopUp), form.row("", chatHint)]
        form.row("", summarizeIncoming)
        form.row("Templates", NSButton.push("Edit Custom Templates…") { [weak self] in
            self?.presentSheet(TemplatesSheetController())
        })
        form.separator()
        form.row("Models", list, top: true)
        form.row("", NSButton.push("Add Model…") { [weak self] in
            self?.presentSheet(AddModelSheetController { self?.refreshSummaryModels() })
        })
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        models.refreshLLM()
        refreshSummaryModels()
    }

    /// The default must be something that can be chosen.
    private func refreshSummaryModels() {
        SummaryModel.repairCurrent()
        render()
    }

    override func render() {
        let llm = models.llm
        if llm != lastLLM {
            lastLLM = llm
            if let message = failures.newFailure(Dictionary(uniqueKeysWithValues: llm.map { ($0.key.rawValue, $0.value) })) {
                Alerts.inform("Download Failed", message: message, in: view.window)
            }
            // A model that arrived or left changes what can be the default.
            DispatchQueue.main.async { SummaryModel.repairCurrent() }
        }

        summarizeIncoming.isOn = AppSettings.summarizeIncoming
        let available = SummaryModel.available
        let current = SummaryModel.current
        let hasModels = !available.isEmpty
        if popUpRow?.isHidden != !hasModels || noneRow?.isHidden != hasModels {
            popUpRow?.isHidden = !hasModels
            noneRow?.isHidden = hasModels
            contentChanged()
        }
        defaultPopUp.set(available.map(\.name), selected: available.firstIndex(of: current))
        chatPopUp.set(["Same as Default"] + available.map(\.name), selected: SummaryModel.chatChoice.flatMap { available.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        let hint = SummaryModel.chat.sendsHint("question and excerpts of your notes") ?? ""
        let showsHint = hasModels && !hint.isEmpty
        chatHint.stringValue = hint
        if chatRows.first?.isHidden != !hasModels || chatRows.last?.isHidden != !showsHint {
            chatRows.first?.isHidden = !hasModels
            chatRows.last?.isHidden = !showsHint
            contentChanged()
        }

        renderList()
    }

    /// Apple's model when the system has it, the local models on the device or on the way, then the cloud models.
    private func renderList() {
        var entries: [(id: String, make: () -> ModelStateRow, state: ModelManager.State)] = []
        if AppleLLM.availability == .available {
            entries.append(("apple", {
                ModelStateRow(title: LocalModel.apple.displayName, subtitle: "On this device · built into the system") {}
            }, .installed))
        }
        for model in addedLocalModels {
            entries.append(("local." + model.rawValue, { [weak self] in
                ModelStateRow(
                    title: model.displayName, subtitle: "On this device · " + model.sizeText,
                    onDelete: { self?.confirmDelete(model) },
                    onCancel: { Task { await ModelManager.shared.deleteLLM(model) } }
                ) {
                    Task { await ModelManager.shared.downloadLLM(model) }
                }
            }, models.llmState(model)))
        }
        for model in SummaryModel.external {
            entries.append(("external." + model.id, { [weak self] in
                ModelStateRow(title: model.name, subtitle: model.place, onDelete: { self?.confirmRemove(model) }) {}
            }, .installed))
        }

        let ids = entries.map(\.id)
        if ids != listIDs {
            listIDs = ids
            list.arrangedSubviews.forEach { $0.removeFromSuperview() }
            var kept: [String: ModelStateRow] = [:]
            for entry in entries {
                let row = rows[entry.id] ?? entry.make()
                kept[entry.id] = row
                list.addArrangedSubview(row)
            }
            rows = kept
            if entries.isEmpty {
                list.addArrangedSubview(SettingsForm.footnote("No models added yet."))
            }
            contentChanged()
        }
        for entry in entries { rows[entry.id]?.update(entry.state) }
    }

    /// On the device or on the way there. The others are offered in the Add Model sheet.
    private var addedLocalModels: [LocalModel] {
        LocalModel.downloadable.filter { model in
            switch models.llmState(model) {
            case .installed, .ready, .downloading, .loading: true
            default: false
            }
        }
    }

    private func confirmDelete(_ model: LocalModel) {
        Alerts.confirm("Delete \(model.displayName)?", message: "You can download it again at any time.", action: "Delete", in: view.window) {
            Task { await ModelManager.shared.deleteLLM(model) }
        }
    }

    private func confirmRemove(_ model: SummaryModel) {
        Alerts.confirm("Remove \(model.name)?", message: "You can add it again at any time.", action: "Remove", in: view.window) { [weak self] in
            SummaryModel.remove(model)
            self?.refreshSummaryModels()
        }
    }
}
