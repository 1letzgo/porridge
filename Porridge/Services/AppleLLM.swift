import Foundation
import FoundationModels

enum AppleLLMError: LocalizedError {
    case unavailable
    case tooLong
    case refused
    case unsupportedLanguage

    var errorDescription: String? {
        switch self {
        case .unavailable: "Apple Intelligence is not available on this device right now."
        case .tooLong: "This is too long for the Apple model. Try one of the downloaded models."
        case .refused: "The Apple model declined this text. Try one of the downloaded models."
        case .unsupportedLanguage: "The Apple model does not support this language. Try one of the downloaded models."
        }
    }
}

/// The language model built into the system (Apple Intelligence): nothing to download, but a small window of about
/// 4,000 tokens for the question and the answer together.
enum AppleLLM {
    enum Availability {
        case available
        /// The device could, but Apple Intelligence is turned off.
        case notEnabled
        /// The system is still fetching the model.
        case notReady
        /// Too old a system or device: not worth mentioning in the settings.
        case unsupported
    }

    static var availability: Availability {
        guard #available(iOS 26, macOS 26, *) else { return .unsupported }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
        case .unavailable(.modelNotReady): return .notReady
        case .unavailable: return .unsupported
        }
    }

    static func generate(system: String, user: String, maxTokens: Int) async throws -> String {
        guard #available(iOS 26, macOS 26, *), availability == .available else { throw AppleLLMError.unavailable }
        let session = LanguageModelSession(instructions: system)
        let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: maxTokens)
        do {
            let text = try await session.respond(to: user, options: options).content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw LocalLLMError.emptyResponse }
            return text
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            throw AppleLLMError.tooLong
        } catch LanguageModelSession.GenerationError.guardrailViolation {
            throw AppleLLMError.refused
        } catch LanguageModelSession.GenerationError.refusal {
            throw AppleLLMError.refused
        } catch LanguageModelSession.GenerationError.unsupportedLanguageOrLocale {
            throw AppleLLMError.unsupportedLanguage
        }
    }
}
