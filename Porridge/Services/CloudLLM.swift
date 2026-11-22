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
        try await completion(provider: provider, apiKey: apiKey, model: model, system: system, user: user).text
    }

    /// `truncated`: the provider stopped at its output limit, so the text ends in the middle.
    static func completion(provider: AIProvider, apiKey: String, model: String, system: String, user: String) async throws -> (text: String, truncated: Bool) {
        let reply = try await respond(provider: provider, apiKey: apiKey, model: model, system: system, user: user, tools: [])
        return (reply.text, reply.truncated)
    }

    // MARK: - Tools

    /// A tool the model called, with its arguments.
    struct ToolCall {
        let name: String
        let arguments: [String: Any]
    }

    /// The provider (or the model behind it) does not take tools: the caller asks again without them.
    struct ToolsUnsupported: Error {}

    /// The answer and the tools the model wants called (the chat's actions). They are not run here and not answered:
    /// the user confirms them first. A provider that refuses tools throws `ToolsUnsupported`.
    static func chat(
        provider: AIProvider, apiKey: String, model: String, system: String, user: String, tools: [ChatActionTools.Tool]
    ) async throws -> (text: String, calls: [ToolCall]) {
        let reply = try await respond(provider: provider, apiKey: apiKey, model: model, system: system, user: user, tools: tools)
        return (reply.text, reply.calls)
    }

    /// The tools as the provider's request names them.
    static func toolsBody(_ tools: [ChatActionTools.Tool], style: AIProvider.Style) -> Any {
        switch style {
        case .openAICompatible:
            tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.parameters]] }
        case .anthropic:
            tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.parameters] }
        case .google:
            [["functionDeclarations": tools.map { ["name": $0.name, "description": $0.description, "parameters": $0.parameters] }]]
        }
    }

    /// The tool calls in a provider's answer: `tool_calls` (OpenAI style, arguments as a JSON string), `tool_use`
    /// blocks (Anthropic), `functionCall` parts (Google).
    static func toolCalls(in json: [String: Any], style: AIProvider.Style) -> [ToolCall] {
        switch style {
        case .openAICompatible:
            let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            return (message?["tool_calls"] as? [[String: Any]] ?? []).compactMap { call in
                guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
                var arguments = function["arguments"] as? [String: Any] ?? [:]
                if let text = function["arguments"] as? String, let data = text.data(using: .utf8) {
                    arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                }
                return ToolCall(name: name, arguments: arguments)
            }
        case .anthropic:
            return (json["content"] as? [[String: Any]] ?? []).compactMap { block in
                guard block["type"] as? String == "tool_use", let name = block["name"] as? String else { return nil }
                return ToolCall(name: name, arguments: block["input"] as? [String: Any] ?? [:])
            }
        case .google:
            let parts = (((json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"]) as? [[String: Any]] ?? []
            return parts.compactMap { part in
                guard let call = part["functionCall"] as? [String: Any], let name = call["name"] as? String else { return nil }
                return ToolCall(name: name, arguments: call["args"] as? [String: Any] ?? [:])
            }
        }
    }

    private static func respond(
        provider: AIProvider, apiKey: String, model: String, system: String, user: String, tools: [ChatActionTools.Tool]
    ) async throws -> (text: String, truncated: Bool, calls: [ToolCall]) {
        guard let base = provider.resolvedBaseURL else { throw SummaryError.missingBaseURL }
        guard !model.isEmpty else { throw SummaryError.missingModel }

        var request: URLRequest
        var body: [String: Any]

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

        if !tools.isEmpty {
            body["tools"] = toolsBody(tools, style: provider.style)
            if provider.style == .openAICompatible { body["tool_choice"] = "auto" }
        }

        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await send(request, provider: provider, withTools: !tools.isEmpty)
        let calls = tools.isEmpty ? [] : toolCalls(in: json, style: provider.style)
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
        // Only tool calls and no words is an answer too.
        guard (text?.isEmpty == false) || !calls.isEmpty else { throw SummaryError.emptyResponse }
        let stop: String? = switch provider.style {
        case .openAICompatible: (json["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String
        case .anthropic: json["stop_reason"] as? String
        case .google: (json["candidates"] as? [[String: Any]])?.first?["finishReason"] as? String
        }
        return (text ?? "", isTruncation(stop), calls)
    }

    /// "length" (OpenAI style), "max_tokens" (Anthropic), "MAX_TOKENS" (Google).
    static func isTruncation(_ stopReason: String?) -> Bool {
        guard let reason = stopReason?.lowercased() else { return false }
        return reason == "length" || reason == "max_tokens"
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

    /// A failed request as a message that says what to do: a key that is not accepted, a limit, or what the service said.
    static func error(status: Int, message: String, provider: AIProvider) -> SummaryError {
        let name = provider == .custom ? "Your server" : provider.label
        switch status {
        case 401, 403: return .provider("\(name) did not accept the API key. Check it in Settings, under AI.")
        case 429: return .provider("\(name) is busy or your usage limit is reached. Try again later.")
        case 500...599: return .provider("\(name) has a problem right now (\(status)). Try again later.")
        default: return .provider("\(name): \(message)")
        }
    }

    private static func send(_ request: URLRequest, provider: AIProvider, withTools: Bool = false) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A request with tools that is refused as such (a model or server without tool calling): asked again without.
        if withTools, [400, 404, 405, 422, 501].contains(status) { throw ToolsUnsupported() }
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error?.message ?? "HTTP \(status)"
            throw CloudLLM.error(status: status, message: message, provider: provider)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SummaryError.emptyResponse
        }
        return json
    }
}
