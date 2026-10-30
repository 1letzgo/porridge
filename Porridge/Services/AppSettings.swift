import FluidAudio
import Foundation

/// Where summaries are written: a model on the device, or a cloud provider with the user's own key.
enum SummaryBilling: String, CaseIterable, Identifiable {
    case local
    case byok

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: "On-Device"
        case .byok: "Cloud"
        }
    }
}

enum SpeechEngine: String, CaseIterable, Identifiable {
    case parakeet
    case apple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .parakeet: "Parakeet v3"
        case .apple: "Apple (built in)"
        }
    }

    /// Short name for the settings switcher.
    var shortLabel: String {
        switch self {
        case .parakeet: "Parakeet"
        case .apple: "Apple"
        }
    }

    /// The engines this device offers (Apple's model needs iOS/macOS 26 with on-device speech).
    static var available: [SpeechEngine] {
        AppleSpeech.isSupported ? [.apple, .parakeet] : [.parakeet]
    }
}

enum AppSettings {
    static let speechEngineKey = "speechEngine"
    static let onboardingDoneKey = "onboardingDone"
    static let languageKey = "transcriptionLanguage"
    static let speakerDetectionKey = "speakerDetection"
    static let billingKey = "summaryBilling"
    static let localModelKey = "localModel"
    static let voiceRecognitionKey = "voiceRecognition"
    static let providerKey = "aiProvider"
    static let customBaseURLKey = "aiCustomBaseURL"

    static let languages: [(code: String, name: String)] = [
        ("auto", "Automatic"),
        ("de", "German"),
        ("en", "English"),
        ("fr", "French"),
        ("es", "Spanish"),
        ("it", "Italian"),
        ("nl", "Dutch"),
        ("pt", "Portuguese"),
        ("pl", "Polish"),
    ]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            languageKey: "auto",
            // The model built into the system needs no download; Parakeet where it is missing.
            speechEngineKey: (AppleSpeech.isSupported ? SpeechEngine.apple : SpeechEngine.parakeet).rawValue,
            onboardingDoneKey: false,
            speakerDetectionKey: true,
            billingKey: SummaryBilling.local.rawValue,
            localModelKey: LocalModel.qwen3.rawValue,
            voiceRecognitionKey: true,
            providerKey: AIProvider.openRouter.rawValue,
        ])
    }

    static var language: Language? {
        Language(rawValue: UserDefaults.standard.string(forKey: languageKey) ?? "auto")
    }

    static var speechEngine: SpeechEngine {
        let stored = SpeechEngine(rawValue: UserDefaults.standard.string(forKey: speechEngineKey) ?? "") ?? .parakeet
        return stored == .apple && !AppleSpeech.isSupported ? .parakeet : stored
    }

    static var voiceRecognitionEnabled: Bool {
        UserDefaults.standard.bool(forKey: voiceRecognitionKey)
    }

    static var speakerDetectionEnabled: Bool {
        UserDefaults.standard.bool(forKey: speakerDetectionKey)
    }

    static var billing: SummaryBilling {
        SummaryBilling(rawValue: UserDefaults.standard.string(forKey: billingKey) ?? "") ?? .local
    }
}
