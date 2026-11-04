import Foundation

/// A model that writes summaries. On this device or with the user's own key, it is treated the same everywhere:
/// one list in the settings, one default, and a choice each time a meeting is summarized.
///
/// The default stays in the settings it always was in (`billingKey`, `localModelKey`, `providerKey`, `aiModel.…`).
enum SummaryModel: Hashable, Identifiable {
    case local(LocalModel)
    case cloud(AIProvider, String)

    var id: String {
        switch self {
        case .local(let model): "local:\(model.rawValue)"
        case .cloud(let provider, let model): "cloud:\(provider.rawValue):\(model)"
        }
    }

    var name: String {
        switch self {
        case .local(let model): model.displayName
        case .cloud(let provider, let model): provider.suggestedModels.first { $0.id == model }?.name ?? model
        }
    }

    /// Where it runs.
    var place: String {
        switch self {
        case .local: "On this device"
        case .cloud(let provider, _): provider.label
        }
    }

    /// In a menu, where both have to fit one line.
    var menuTitle: String { "\(name) · \(place)" }

    /// As it is named next to a finished summary.
    var label: String {
        switch self {
        case .local(let model): "\(model.displayName) (on-device)"
        case .cloud(let provider, let model): "\(provider.label) · \(model)"
        }
    }

    var isCloud: Bool {
        if case .cloud = self { true } else { false }
    }

    /// Ready to run without a download first.
    var isOnHand: Bool {
        switch self {
        case .local(let model): model.isInstalled
        case .cloud: true
        }
    }

    // MARK: - The default

    static var current: SummaryModel {
        get {
            switch AppSettings.billing {
            case .local: .local(.selected)
            case .byok: .cloud(.current, AIProvider.current.model)
            }
        }
        set {
            let defaults = UserDefaults.standard
            switch newValue {
            case .local(let model):
                defaults.set(SummaryBilling.local.rawValue, forKey: AppSettings.billingKey)
                defaults.set(model.rawValue, forKey: AppSettings.localModelKey)
            case .cloud(let provider, let model):
                defaults.set(SummaryBilling.byok.rawValue, forKey: AppSettings.billingKey)
                defaults.set(provider.rawValue, forKey: AppSettings.providerKey)
                provider.model = model
            }
        }
    }

    // MARK: - The list

    private struct Stored: Codable {
        var provider: String
        var model: String
    }

    /// The cloud models that were added, on this device. Keys stay per provider (`AIProvider.keyAccount`).
    static var external: [SummaryModel] {
        get {
            let defaults = UserDefaults.standard
            guard let data = defaults.data(forKey: AppSettings.externalModelsKey),
                  let stored = try? JSONDecoder().decode([Stored].self, from: data) else {
                return carriedOver()
            }
            return stored.compactMap { item in
                AIProvider(rawValue: item.provider).map { .cloud($0, item.model) }
            }
        }
        set {
            let stored = newValue.compactMap { model -> Stored? in
                guard case .cloud(let provider, let id) = model else { return nil }
                return Stored(provider: provider.rawValue, model: id)
            }
            UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: AppSettings.externalModelsKey)
        }
    }

    /// From before there was a list: every service with a key brings the model it had chosen, so nothing set up is lost.
    private static func carriedOver() -> [SummaryModel] {
        var models: [SummaryModel] = []
        for provider in AIProvider.allCases where !provider.model.isEmpty {
            let isSetUp = provider == .custom ? !AIProvider.customBaseURL.isEmpty : !provider.apiKey.isEmpty
            if isSetUp { models.append(.cloud(provider, provider.model)) }
        }
        if case .cloud = current, !models.contains(current) { models.insert(current, at: 0) }
        external = models
        return models
    }

    static func add(_ model: SummaryModel) {
        var models = external
        guard case .cloud = model, !models.contains(model) else { return }
        models.append(model)
        external = models
    }

    static func remove(_ model: SummaryModel) {
        external = external.filter { $0 != model }
        repairCurrent()
    }

    /// What can be chosen: what is on the device, built into the system, or was added.
    static var available: [SummaryModel] {
        LocalModel.allCases.filter(\.isInstalled).map(SummaryModel.local) + external
    }

    /// The default must be something that can be chosen. With nothing there it stays: a local model then downloads when used.
    static func repairCurrent() {
        let models = available
        if let first = models.first, !models.contains(current) { current = first }
    }
}
