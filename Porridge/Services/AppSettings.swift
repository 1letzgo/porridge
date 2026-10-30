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
    /// The user's own name (and other ways it is written, comma separated): their tasks go under "Mine".
    static let myNameKey = "myName"
    /// The voice marked as the user's in the speaker list (`VoiceProfile.id`), and its name for matching.
    static let myVoiceKey = "myVoice"
    static let myVoiceNameKey = "myVoiceName"

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

    /// The names the user goes by, lowercased; empty when none is set.
    static var myNames: [String] {
        myNames(from: UserDefaults.standard.string(forKey: myNameKey) ?? "", voice: UserDefaults.standard.string(forKey: myVoiceNameKey) ?? "")
    }

    /// The user's name as they wrote it first, for the summaries; nil when none is set.
    static var myName: String? {
        (UserDefaults.standard.string(forKey: myNameKey) ?? "").split(separator: ",").first
            .map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? UserDefaults.standard.string(forKey: myVoiceNameKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether a speaker is the user: the voice marked as the user's, or a name of the user.
    static func isMe(_ speaker: Speaker) -> Bool {
        if let id = speaker.profileID, id == UserDefaults.standard.string(forKey: myVoiceKey) { return true }
        return isMe(speaker.name)
    }

    /// Marks a voice as the user's (nil: none).
    static func setMyVoice(_ profile: VoiceProfile?) {
        UserDefaults.standard.set(profile?.id.uuidString, forKey: myVoiceKey)
        UserDefaults.standard.set(profile?.name, forKey: myVoiceNameKey)
        Task { @MainActor in NextcloudSync.shared.syncSoon() }
    }

    /// Whether a speaker or owner name is the user: the whole name or the first name of either side matches.
    static func isMe(_ name: String, names: [String] = myNames) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return false }
        return names.contains { mine in
            name == mine || name.split(separator: " ").first.map(String.init) == mine
                || mine.split(separator: " ").first.map(String.init) == name
        }
    }

    static func myNames(from raw: String, voice: String = "") -> [String] {
        (raw.split(separator: ",").map(String.init) + [voice])
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
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
