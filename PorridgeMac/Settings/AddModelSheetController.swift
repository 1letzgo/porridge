import AppKit

/// Adds a summary model: one of the on-device models that is not downloaded yet, or one from a cloud service
/// (its key, once for all its models, and the model). The Mac form of `AddModelSheet`.
final class AddModelSheetController: NSViewController {
    private let onChange: () -> Void
    private let models = ModelManager.shared
    private var observers: [Observing] = []
    private let container = NSView()

    // The list page.
    private var localList = NSStackView()
    private var localRows: [LocalModel: ModelStateRow] = [:]
    private var localIDs: [LocalModel] = []

    // The page of a service.
    private var provider: AIProvider?
    private var customURLField: SettingsTextField?
    private var keyField: SettingsSecureField?
    private var modelPopUp: SettingsPopUp?
    private var modelPopUpRow: NSGridRow?
    private var modelField: SettingsTextField?
    private var errorLabel: NSTextField?
    private var addButton: NSButton?
    private var fetched: [String] = []
    private var loadTask: Task<Void, Never>?

    private static let width: CGFloat = 480

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
        title = "Add Model"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.width),
            container.heightAnchor.constraint(equalToConstant: 540),
        ])
        view = container
        showList()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        observers.cancelAll()
        loadTask?.cancel()
        onChange()
    }

    private func setPage(_ page: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        container.addSubview(page)
        page.pinEdges(to: container)
    }

    // MARK: - List

    private var notDownloaded: [LocalModel] {
        LocalModel.downloadable.filter { model in
            switch models.llmState(model) {
            case .installed, .ready: false
            default: true
            }
        }
    }

    private func showList() {
        observers.cancelAll()
        provider = nil
        loadTask?.cancel()
        let contentWidth = Self.width - 40
        let (scroll, stack) = SettingsSheet.scrollingStack(spacing: 14)
        stack.addArrangedSubview(SettingsSheet.sectionHead("On This Device", width: contentWidth))
        switch AppleLLM.availability {
        case .available, .unsupported:
            break
        case .notEnabled:
            stack.addArrangedSubview(valueRow(LocalModel.apple.displayName, "Turned off in system settings", width: contentWidth))
        case .notReady:
            stack.addArrangedSubview(valueRow(LocalModel.apple.displayName, "System is preparing it", width: contentWidth))
        }
        localList = NSStackView.vertical([], spacing: 12)
        localRows = [:]
        localIDs = []
        stack.addArrangedSubview(localList)
        stack.setCustomSpacing(26, after: localList)

        stack.addArrangedSubview(SettingsSheet.sectionHead("Cloud Service", width: contentWidth))
        for (index, provider) in AIProvider.allCases.enumerated() {
            if index > 0 { stack.addArrangedSubview(SettingsSheet.hairline(width: contentWidth)) }
            let button = ActionButton(title: provider.label, symbol: "chevron.right") { [weak self] in self?.showProvider(provider) }
            button.image = .symbol("chevron.right", size: 11, weight: .semibold)
            button.imagePosition = .imageTrailing
            button.isBordered = false
            button.alignment = .left
            button.contentTintColor = .labelColor
            button.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            button.setAccessibilityLabel(provider.label)
            stack.addArrangedSubview(button)
        }

        let done = SettingsSheet.defaultButton("Done") { [weak self] in self?.dismiss(nil) }
        let page = NSStackView.vertical([header("Add Model"), scroll, SettingsSheet.footer(right: [done])], spacing: 0, alignment: .leading)
        scroll.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
        page.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
        setPage(page)
        observers.append(Observing { [weak self] in self?.renderList() })
    }

    private func renderList() {
        let list = notDownloaded
        if list != localIDs {
            localIDs = list
            localList.arrangedSubviews.forEach { $0.removeFromSuperview() }
            var kept: [LocalModel: ModelStateRow] = [:]
            for model in list {
                let row = localRows[model] ?? ModelStateRow(
                    title: model.displayName,
                    subtitle: (model == .recommended ? "Recommended for this device · " : "") + model.sizeText,
                    width: Self.width - 40,
                    onCancel: { Task { await ModelManager.shared.deleteLLM(model) } }
                ) { [weak self] in
                    Task {
                        await ModelManager.shared.downloadLLM(model)
                        self?.onChange()
                    }
                }
                kept[model] = row
                localList.addArrangedSubview(row)
            }
            localRows = kept
            if list.isEmpty, AppleLLM.availability == .available {
                localList.addArrangedSubview(SettingsForm.footnote("All on-device models are added."))
            }
        }
        for model in list { localRows[model]?.update(models.llmState(model)) }
    }

    private func valueRow(_ title: String, _ value: String, width: CGFloat) -> NSView {
        let valueLabel = NSTextField.label(value, color: .secondaryLabelColor)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView.horizontal([NSTextField.label(title), spacer, valueLabel])
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        return row
    }

    private func header(_ text: String) -> NSView {
        let title = SettingsSheet.title(text)
        let bar = NSStackView.horizontal([title])
        bar.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 10, right: 20)
        return bar
    }

    // MARK: - A cloud service

    private func showProvider(_ provider: AIProvider) {
        observers.cancelAll()
        self.provider = provider
        fetched = []
        let form = SettingsForm()
        form.grid.column(at: 0).width = 90
        form.grid.column(at: 1).width = 320
        if provider == .custom {
            let field = SettingsTextField(placeholder: "Server address, e.g. http://192.168.1.5:11434/v1", width: 320) { [weak self] text in
                UserDefaults.standard.set(text, forKey: AppSettings.customBaseURLKey)
                self?.renderProvider()
            }
            field.stringValue = UserDefaults.standard.string(forKey: AppSettings.customBaseURLKey) ?? ""
            customURLField = field
            form.row("Server", field)
        } else {
            customURLField = nil
        }
        let key = SettingsSecureField(
            placeholder: provider.requiresKey ? "\(provider.label) API Key" : "API Key (optional)", width: 320
        ) { [weak self] _ in
            self?.keyChanged()
        }
        key.stringValue = provider.apiKey
        keyField = key
        form.row("API Key", key)
        let popUp = SettingsPopUp { [weak self] index in
            guard let self, index >= 0 else { return }
            let options = self.options
            guard index < options.count else { return }
            self.modelField?.stringValue = options[index].value
            self.renderProvider()
        }
        modelPopUp = popUp
        modelPopUpRow = form.row("Model", popUp)
        let modelID = SettingsTextField(placeholder: "Model ID", width: 320) { [weak self] _ in self?.renderProvider() }
        modelID.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        modelID.stringValue = provider.suggestedModels.first?.id ?? ""
        modelField = modelID
        form.row("Model ID", modelID)
        let error = form.note(color: .brandDangerText)
        error.label.preferredMaxLayoutWidth = 320
        errorLabel = error.label

        let back = SettingsSheet.cancelButton("Back") { [weak self] in self?.showList() }
        let add = SettingsSheet.defaultButton("Add Model") { [weak self] in self?.add() }
        addButton = add

        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(form.grid)
        NSLayoutConstraint.activate([
            form.grid.topAnchor.constraint(equalTo: body.topAnchor, constant: 8),
            form.grid.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 20),
        ])
        let page = NSStackView.vertical([header(provider.label), body, SettingsSheet.footer(left: [back], right: [add])], spacing: 0, alignment: .leading)
        page.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
        body.setContentHuggingPriority(.init(1), for: .vertical)
        setPage(page)
        view.window?.makeFirstResponder(provider == .custom ? customURLField : key)
        renderProvider()
        keyChanged()
    }

    private var trimmedKey: String { (keyField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedModel: String { (modelField?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canAdd: Bool {
        guard let provider, !trimmedModel.isEmpty else { return false }
        if provider == .custom { return !(customURLField?.stringValue ?? "").isEmpty }
        return !trimmedKey.isEmpty
    }

    private var options: [(value: String, title: String)] {
        guard let provider else { return [] }
        var list = fetched.isEmpty
            ? provider.suggestedModels.map { (value: $0.id, title: $0.name) }
            : fetched.map { (value: $0, title: $0) }
        if !trimmedModel.isEmpty, !list.contains(where: { $0.value == trimmedModel }) {
            list.append((value: trimmedModel, title: trimmedModel))
        }
        return list
    }

    private func renderProvider() {
        guard let provider else { return }
        let options = options
        // A server of your own has no list: there the field is all there is.
        modelPopUpRow?.isHidden = fetched.isEmpty && provider.suggestedModels.isEmpty
        modelPopUp?.set(options.map(\.title), selected: options.firstIndex { $0.value == trimmedModel })
        addButton?.isEnabled = canAdd
    }

    /// The list of models of the service, a moment after the key stopped changing.
    private func keyChanged() {
        renderProvider()
        loadTask?.cancel()
        fetched = []
        errorLabel?.stringValue = ""
        guard let provider, provider.canListModels, !trimmedKey.isEmpty else { return }
        let key = trimmedKey
        loadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            do {
                let list = try await CloudLLM.models(provider: provider, apiKey: key)
                guard !Task.isCancelled, let self else { return }
                self.fetched = list
                if !list.isEmpty, !list.contains(self.trimmedModel) {
                    let preferred = ["haiku", "flash", "mini", "luna", "small"]
                    self.modelField?.stringValue = list.first { id in preferred.contains { id.lowercased().contains($0) } } ?? list[0]
                }
                self.renderProvider()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorLabel?.stringValue = error.localizedDescription
            }
        }
    }

    private func add() {
        guard let provider, canAdd else { return }
        Keychain.set(trimmedKey, for: provider.keyAccount)
        SummaryModel.add(.cloud(provider, trimmedModel))
        SummaryModel.repairCurrent()
        onChange()
        dismiss(nil)
    }
}
