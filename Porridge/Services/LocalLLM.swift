import Foundation
import HuggingFace
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

enum LocalLLMError: LocalizedError {
    case invalidModelID(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidModelID(let id): "Invalid model id: \(id)"
        case .emptyResponse: "The on-device model returned no text."
        }
    }
}

/// On-device language models that can write the summary. Each one is downloaded on its own.
enum LocalModel: String, CaseIterable, Identifiable {
    case qwen3
    case qwen35

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .qwen3: "Qwen3 4B"
        case .qwen35: "Qwen3.5 4B"
        }
    }

    var repoID: String {
        switch self {
        case .qwen3: "mlx-community/Qwen3-4B-Instruct-2507-4bit"
        case .qwen35: "mlx-community/Qwen3.5-4B-MLX-4bit"
        }
    }

    var sizeText: String {
        switch self {
        case .qwen3: "approx. 2.3 GB"
        case .qwen35: "approx. 3.1 GB"
        }
    }

    /// The model used for summaries.
    static var selected: LocalModel {
        LocalModel(rawValue: UserDefaults.standard.string(forKey: AppSettings.localModelKey) ?? "") ?? .qwen3
    }

    /// Size of the finished download; a smaller folder means the download was interrupted.
    var expectedBytes: Int64 {
        switch self {
        case .qwen3: 2_280_000_000
        case .qwen35: 3_060_000_000
        }
    }

    /// Whether the model's files are completely on the device (checked on disk, not remembered).
    var isInstalled: Bool {
        LocalLLM.downloadedBytes(self) >= expectedBytes * 95 / 100
    }
}

/// Small on-device language model for meeting summaries, run with MLX.
/// A model is downloaded once from Hugging Face and loaded into memory only while summarizing.
actor LocalLLM {
    static let shared = LocalLLM()

    private var container: ModelContainer?
    private var loadedModel: LocalModel?
    private var loading: Task<ModelContainer, Error>?
    private var loadingModel: LocalModel?

    /// Every model keeps its files in its own folder in Application Support, left out of device backups.
    private static func directory(for model: LocalModel) -> URL {
        migrateLegacyFilesIfNeeded()
        var directory = root.appendingPathComponent(model.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return directory
    }

    private static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Models/LLM", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Bytes of finished downloads in a model's folder. Partial downloads (`.incomplete`) don't count.
    static func downloadedBytes(_ model: LocalModel) -> Int64 {
        let directory = directory(for: model)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files where url.pathComponents.contains("blobs") && url.pathExtension != "incomplete" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// Before there were two models, the first one's files lay directly in the folder.
    private static func migrateLegacyFilesIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "localLLMInstalled") else { return }
        defaults.removeObject(forKey: "localLLMInstalled")
        let target = root.appendingPathComponent(LocalModel.qwen3.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let reserved = Set(LocalModel.allCases.map(\.rawValue))
        for item in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where !reserved.contains(item) {
            try? FileManager.default.moveItem(at: root.appendingPathComponent(item), to: target.appendingPathComponent(item))
        }
    }

    /// Downloads the model if needed and loads it. `progress` reports the download (0...1).
    func prepare(_ model: LocalModel, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        _ = try await load(model, progress: progress)
    }

    private func load(_ model: LocalModel, progress: (@Sendable (Double) -> Void)?) async throws -> ModelContainer {
        if let container, loadedModel == model { return container }
        if let loading, loadingModel == model { return try await loading.value }
        // Only one model at a time in memory.
        if loadedModel != model { unload() }

        let task = Task<ModelContainer, Error> {
            // Keep MLX's buffer cache small; the weights themselves take most of the memory.
            Memory.cacheLimit = 32 * 1024 * 1024
            let hub = HubClient(cache: HubCache(cacheDirectory: Self.directory(for: model)))
            let container = try await loadModelContainer(
                from: HubBridge(upstream: hub),
                using: TransformersTokenizerLoader(),
                configuration: ModelConfiguration(id: model.repoID),
                progressHandler: { progress?($0.fractionCompleted) }
            )
            return container
        }
        loading = task
        loadingModel = model
        do {
            let container = try await task.value
            self.container = container
            loadedModel = model
            loading = nil
            loadingModel = nil
            return container
        } catch {
            loading = nil
            loadingModel = nil
            throw error
        }
    }

    /// One answer to a system + user message pair, without any history.
    func generate(model: LocalModel, system: String, user: String, maxTokens: Int) async throws -> String {
        let container = try await load(model, progress: nil)
        let session = ChatSession(
            container,
            instructions: system,
            generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.3, topP: 0.9),
            // Qwen3.5 thinks out loud by default; a summary needs only the answer.
            additionalContext: ["enable_thinking": false]
        )
        // A failing GPU (memory, app in the background) is reported as an error instead of ending the app.
        let answer: String
        do {
            answer = try await withError { try await session.respond(to: user) }
        } catch {
            Self.logFailure("\(error.localizedDescription) (prompt \(user.count) characters)")
            throw error
        }
        let text = Self.withoutThinking(answer)
        guard !text.isEmpty else { throw LocalLLMError.emptyResponse }
        return text
    }

    private static func logFailure(_ message: String) {
        print("[llm] failed: \(message)")
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        let url = documents.appendingPathComponent("llm-errors.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Removes a `<think>…</think>` block in case a model writes one anyway.
    private static func withoutThinking(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<think>") {
            if let end = result.range(of: "</think>", range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                result.removeSubrange(start.lowerBound..<result.endIndex)
            }
        }
        return result.replacingOccurrences(of: "</think>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Frees the memory the model uses.
    func unload() {
        // Nothing loaded: nothing to free (and the simulator has no Metal device to ask).
        guard container != nil || loadedModel != nil || loading != nil else { return }
        container = nil
        loadedModel = nil
        Memory.clearCache()
    }

    /// Deletes the downloaded files of a model.
    func delete(_ model: LocalModel) {
        if loadedModel == model || loadingModel == model {
            loading?.cancel()
            loading = nil
            loadingModel = nil
            unload()
        }
        try? FileManager.default.removeItem(at: Self.directory(for: model))
    }
}

// MARK: - Hugging Face glue (written out instead of using the package's macros, so plain xcodebuild works)

private struct HubBridge: MLXLMCommon.Downloader {
    let upstream: HubClient

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = HuggingFace.Repo.ID(rawValue: id) else {
            throw LocalLLMError.invalidModelID(id)
        }
        return try await upstream.downloadSnapshot(
            of: repoID,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
            }
        )
    }
}

private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
