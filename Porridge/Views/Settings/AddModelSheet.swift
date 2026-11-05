import SwiftUI

/// Adds a summary model: one of the on-device models that is not downloaded yet, or one from a cloud service.
struct AddModelSheet: View {
    var onChange: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(ModelManager.self) private var models

    private var notDownloaded: [LocalModel] {
        LocalModel.downloadable.filter { model in
            switch models.llmState(model) {
            case .installed, .ready: false
            default: true
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SettingsCard(title: "On This Device") {
                        if notDownloaded.isEmpty, AppleLLM.availability == .available {
                            Text("All on-device models are added.").font(.subheadline).foregroundStyle(.secondary)
                        }
                        switch AppleLLM.availability {
                        case .available, .unsupported:
                            EmptyView()
                        case .notEnabled:
                            ValueRow(title: LocalModel.apple.displayName, value: "Turned off in system settings")
                        case .notReady:
                            ValueRow(title: LocalModel.apple.displayName, value: "System is preparing it")
                        }
                        ForEach(notDownloaded) { model in
                            ModelRow(
                                title: model.displayName,
                                subtitle: (model == .recommended ? "Recommended for this device · " : "") + model.sizeText,
                                state: models.llmState(model),
                                onCancel: { Task { await models.deleteLLM(model) } }
                            ) {
                                Task { await models.downloadLLM(model) }
                            }
                        }
                    }
                    SettingsCard(title: "Cloud Service") {
                        ForEach(Array(AIProvider.allCases.enumerated()), id: \.element) { index, provider in
                            if index > 0 { CardDivider() }
                            NavigationLink(value: provider) {
                                HStack {
                                    Text(provider.label).font(.body).foregroundStyle(.primary)
                                    Spacer(minLength: 12)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.appBackground)
            .brandNavigationTitle("Add Model")
            .navigationDestination(for: AIProvider.self) { provider in
                AddCloudModelView(provider: provider) {
                    onChange()
                    dismiss()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }
}

/// The key of a service, once for all its models, and the model to add.
private struct AddCloudModelView: View {
    let provider: AIProvider
    let onAdded: () -> Void

    @AppStorage(AppSettings.customBaseURLKey) private var customBaseURL = ""
    @State private var apiKey = ""
    @State private var modelID = ""
    @State private var fetched: [String] = []
    @State private var loadError: String?

    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedModel: String { modelID.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canAdd: Bool {
        guard !trimmedModel.isEmpty else { return false }
        if provider == .custom { return !customBaseURL.isEmpty }
        return !trimmedKey.isEmpty
    }

    private var options: [(value: String, title: String)] {
        var list = fetched.isEmpty
            ? provider.suggestedModels.map { (value: $0.id, title: $0.name) }
            : fetched.map { (value: $0, title: $0) }
        if !trimmedModel.isEmpty, !list.contains(where: { $0.value == trimmedModel }) {
            list.append((value: trimmedModel, title: trimmedModel))
        }
        return list
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                SettingsCard(title: provider.label) {
                    if provider == .custom {
                        TextField("Server address, e.g. http://192.168.1.5:11434/v1", text: $customBaseURL)
                            .urlFieldStyle()
                            .brandField()
                    }
                    SecureField(provider.requiresKey ? "\(provider.label) API Key" : "API Key (optional)", text: $apiKey)
                        .secretFieldStyle()
                        .brandField()
                    // A server of your own has no list: there the field below is all there is.
                    if !fetched.isEmpty || !provider.suggestedModels.isEmpty {
                        MenuRow(title: "Model", selection: $modelID, options: options)
                    }
                    TextField("Model ID", text: $modelID)
                        .font(.footnote.monospaced())
                        .plainFieldStyle()
                        .brandField()
                    if let loadError {
                        Text(loadError).font(.footnote).foregroundStyle(Color.brandDangerText)
                    }
                }
                Button("Add Model", action: add)
                    .buttonStyle(ChunkyButtonStyle())
                    .disabled(!canAdd)
            }
            .padding(20)
        }
        .background(Color.appBackground)
        .brandNavigationTitle("Add Model")
        .onAppear {
            apiKey = provider.apiKey
            if modelID.isEmpty { modelID = provider.suggestedModels.first?.id ?? "" }
        }
        .task(id: trimmedKey) { await loadModels() }
    }

    private func loadModels() async {
        fetched = []
        loadError = nil
        guard provider.canListModels, !trimmedKey.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        do {
            let list = try await CloudLLM.models(provider: provider, apiKey: trimmedKey)
            guard !Task.isCancelled else { return }
            fetched = list
            if !list.isEmpty, !list.contains(trimmedModel) {
                let preferred = ["haiku", "flash", "mini", "luna", "small"]
                modelID = list.first { id in preferred.contains { id.lowercased().contains($0) } } ?? list[0]
            }
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func add() {
        Keychain.set(trimmedKey, for: provider.keyAccount)
        SummaryModel.add(.cloud(provider, trimmedModel))
        SummaryModel.repairCurrent()
        onAdded()
    }
}
