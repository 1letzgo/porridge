import Foundation

/// Calls the provider chosen in Settings with the user's own key.
enum CloudLLM {
    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable {
            let message: String?
        }
        let error: Body?
    }

    // MARK: - Summary

    static func complete(provider: AIProvider, apiKey: String, model: String, system: String, user: String) async throws -> String {
        guard let base = provider.resolvedBaseURL else { throw SummaryError.missingBaseURL }
        guard !model.isEmpty else { throw SummaryError.missingModel }

        var request: URLRequest
        let body: [String: Any]

        switch provider.style {
        case .openAICompatible:
            request = URLRequest(url: base.appendingPathComponent("chat/completions"))
            if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            if provider == .openRouter {
                request.setValue("https://letzgo.de/porridge", forHTTPHeaderField: "HTTP-Referer")
                request.setValue("Porridge", forHTTPHeaderField: "X-Title")
            }
            body = [
                "model": model,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
            ]
        case .anthropic:
            request = URLRequest(url: base.appendingPathComponent("messages"))
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": model,
                "max_tokens": 4096,
                "system": system,
                "messages": [["role": "user", "content": user]],
            ]
        case .google:
            request = URLRequest(url: base.appendingPathComponent("models/\(model):generateContent"))
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            body = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["role": "user", "parts": [["text": user]]]],
            ]
        }

        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await send(request, provider: provider)
        let text: String? = switch provider.style {
        case .openAICompatible:
            ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        case .anthropic:
            (json["content"] as? [[String: Any]])?
                .compactMap { $0["text"] as? String }.joined()
        case .google:
            ((((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"]) as? [[String: Any]])?
                .compactMap { $0["text"] as? String }.joined()
        }
        guard let text, !text.isEmpty else { throw SummaryError.emptyResponse }
        return text
    }

    // MARK: - Model list

    /// Chat models available to this key, as the provider reports them.
    static func models(provider: AIProvider, apiKey: String) async throws -> [String] {
        guard provider.canListModels, let base = provider.resolvedBaseURL else { return [] }
        var request: URLRequest

        switch provider.style {
        case .openAICompatible:
            request = URLRequest(url: base.appendingPathComponent("models"))
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            var components = URLComponents(url: base.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "limit", value: "100")]
            request = URLRequest(url: components.url!)
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .google:
            var components = URLComponents(url: base.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "pageSize", value: "200")]
            request = URLRequest(url: components.url!)
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        request.timeoutInterval = 30

        let json = try await send(request, provider: provider)
        switch provider.style {
        case .google:
            return (json["models"] as? [[String: Any]] ?? [])
                .filter { ($0["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true }
                .compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
                .filter { $0.hasPrefix("gemini") }
                .sorted(by: >)
        case .anthropic:
            return (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        case .openAICompatible:
            let skip = ["embed", "whisper", "tts", "dall-e", "moderation", "audio", "realtime", "image", "transcribe", "ocr"]
            return (json["data"] as? [[String: Any]] ?? [])
                .compactMap { $0["id"] as? String }
                .filter { id in !skip.contains { id.lowercased().contains($0) } }
                .sorted(by: >)
        }
    }

    // MARK: - Transport

    private static func send(_ request: URLRequest, provider: AIProvider) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error?.message ?? "HTTP \(status)"
            throw SummaryError.provider("\(provider.label): \(message)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SummaryError.emptyResponse
        }
        return json
    }
}
