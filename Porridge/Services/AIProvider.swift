import Foundation

/// The one cloud service the user brings their own key for. It writes summaries and, where the
/// service offers speech-to-text (OpenAI `audio/transcriptions` dialect), transcribes recordings too.
enum AIProvider: String, CaseIterable, Identifiable {
    case openRouter
    case openAI
    case anthropic
    case google
    case mistral
    case groq
    case custom

    enum Style {
        /// `POST {base}/chat/completions` with a Bearer key (OpenAI, OpenRouter, Mistral, Ollama, LM Studio, …).
        case openAICompatible
        case anthropic
        case google
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .google: "Google Gemini"
        case .mistral: "Mistral"
        case .groq: "Groq"
        case .custom: "Custom (OpenAI-compatible)"
        }
    }

    var style: Style {
        switch self {
        case .anthropic: .anthropic
        case .google: .google
        default: .openAICompatible
        }
    }

    /// Fixed API address; `nil` for the custom provider, where the user enters it.
    var baseURL: String? {
        switch self {
        case .openRouter: "https://openrouter.ai/api/v1"
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .google: "https://generativelanguage.googleapis.com/v1beta"
        case .mistral: "https://api.mistral.ai/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .custom: nil
        }
    }

    /// A local server (Ollama, LM Studio) often needs no key.
    var requiresKey: Bool { self != .custom }

    /// Whether the provider can list its models with the key (OpenRouter has too many for a menu).
    var canListModels: Bool { self != .openRouter && self != .custom }

    /// Keychain account of this provider's key. OpenRouter keeps its original name.
    var keyAccount: String { self == .openRouter ? "openrouter-api-key" : "api-key.\(rawValue)" }

    /// Shown until the provider's own model list has been loaded.
    var suggestedModels: [(id: String, name: String)] {
        switch self {
        case .openRouter:
            [
                ("anthropic/claude-haiku-5.5", "Claude Haiku 5.5"),
                ("google/gemini-3.8-flash", "Gemini 3.8 Flash"),
                ("openai/gpt-6-luna", "GPT-6 Luna"),
                ("anthropic/claude-sonnet-5.5", "Claude Sonnet 5.5"),
            ]
        case .openAI: [("gpt-6-luna", "GPT-6 Luna")]
        case .anthropic: [("claude-haiku-5-5", "Claude Haiku 5.5")]
        case .google: [("gemini-3.8-flash", "Gemini 3.8 Flash")]
        case .mistral: [("mistral-small-latest", "Mistral Small")]
        case .groq: [("openai/gpt-oss-120b", "GPT-OSS 120B")]
        case .custom: []
        }
    }

    // MARK: - Stored settings

    private static let providerKey = AppSettings.providerKey
    private static let customBaseURLKey = AppSettings.customBaseURLKey

    static var current: AIProvider {
        AIProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .openRouter
    }

    /// Address of the custom provider.
    static var customBaseURL: String {
        UserDefaults.standard.string(forKey: customBaseURLKey) ?? ""
    }

    /// Selected model; each provider remembers its own.
    var model: String {
        get {
            let defaults = UserDefaults.standard
            if let stored = defaults.string(forKey: "aiModel.\(rawValue)"), !stored.isEmpty { return stored }
            // Before there were several providers, only the OpenRouter model was stored.
            if self == .openRouter, let legacy = defaults.string(forKey: "openRouterModel"), !legacy.isEmpty { return legacy }
            return suggestedModels.first?.id ?? ""
        }
        nonmutating set {
            UserDefaults.standard.set(newValue, forKey: "aiModel.\(rawValue)")
        }
    }

    var apiKey: String {
        Keychain.get(keyAccount) ?? ""
    }

    /// Resolved API address, or `nil` if the custom address is missing or invalid.
    var resolvedBaseURL: URL? {
        let text = (baseURL ?? Self.customBaseURL).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let trimmed = text.hasSuffix("/") ? String(text.dropLast()) : text
        return URL(string: trimmed)
    }
}
