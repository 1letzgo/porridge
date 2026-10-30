import Foundation
import NaturalLanguage
import Observation

/// A passage of a note or a meeting transcript the chat can quote.
struct ChatChunk {
    let noteID: UUID
    let title: String
    let date: Date
    let text: String
    fileprivate let frequencies: [String: Int]
    fileprivate let prefixFrequencies: [String: Int]
    fileprivate let length: Int
}

/// Finds the passages of all notes and meetings that fit a question (keyword ranking, BM25).
enum ChatRetrieval {
    private static let chunkSize = 700

    static func tokens(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = text[range].lowercased()
            if word.count >= 2 { result.append(word) }
            return true
        }
        return result
    }

    private static func prefix(_ token: String) -> String? {
        token.count >= 5 ? String(token.prefix(5)) : nil
    }

    private static func chunk(_ note: Note, text: String) -> ChatChunk {
        let words = tokens(note.displayTitle + " " + note.tags.joined(separator: " ") + " " + text)
        var frequencies: [String: Int] = [:]
        var prefixes: [String: Int] = [:]
        for word in words {
            frequencies[word, default: 0] += 1
            if let key = prefix(word) { prefixes[key, default: 0] += 1 }
        }
        return ChatChunk(
            noteID: note.id, title: note.displayTitle, date: note.createdAt, text: text,
            frequencies: frequencies, prefixFrequencies: prefixes, length: max(words.count, 1)
        )
    }

    /// Cuts text at paragraph breaks into passages of about `chunkSize` characters.
    private static func pieces(_ paragraphs: [String]) -> [String] {
        var result: [String] = []
        var current = ""
        for paragraph in paragraphs {
            let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if !current.isEmpty, current.count + text.count > chunkSize {
                result.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + text
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    static func chunks(from notes: [Note]) -> [ChatChunk] {
        var result: [ChatChunk] = []
        for note in notes where !note.isDeleted {
            if let summary = note.summary, !summary.isEmpty {
                for piece in pieces(summary.components(separatedBy: "\n")) {
                    result.append(chunk(note, text: "Summary: " + piece))
                }
            }
            for piece in pieces(note.text.components(separatedBy: "\n")) {
                result.append(chunk(note, text: piece))
            }
            if let page = note.pageText, !page.isEmpty {
                for piece in pieces(page.components(separatedBy: "\n")) {
                    result.append(chunk(note, text: "Article" + (note.domain.map { " (\($0))" } ?? "") + ": " + piece))
                }
            }
            let speakers = note.speakers
            let lines = note.segments.map { segment -> String in
                let name = segment.speakerId.flatMap { id in speakers.first { $0.id == id }?.name }
                return (name.map { $0 + ": " } ?? "") + segment.text
            }
            for piece in pieces(lines) {
                result.append(chunk(note, text: "Transcript: " + piece))
            }
        }
        return result
    }

    /// The passages that fit `query` best, within `budget` characters.
    static func search(_ query: String, in chunks: [ChatChunk], budget: Int = 6500) -> [ChatChunk] {
        let words = Array(Set(tokens(query)))
        guard !words.isEmpty, !chunks.isEmpty else { return [] }

        let average = Double(chunks.reduce(0) { $0 + $1.length }) / Double(chunks.count)
        let count = Double(chunks.count)
        // A word counts in a chunk when it is there, or another word with the same first five letters (word forms).
        func frequency(_ word: String, _ chunk: ChatChunk) -> Double {
            let exact = Double(chunk.frequencies[word] ?? 0)
            guard let key = prefix(word) else { return exact }
            return exact + 0.5 * Double(chunk.prefixFrequencies[key] ?? 0)
        }

        var scores = [Double](repeating: 0, count: chunks.count)
        for word in words {
            let containing = chunks.filter { frequency(word, $0) > 0 }.count
            guard containing > 0 else { continue }
            let idf = log(1 + (count - Double(containing) + 0.5) / (Double(containing) + 0.5))
            for (index, chunk) in chunks.enumerated() {
                let tf = frequency(word, chunk)
                guard tf > 0 else { continue }
                let k1 = 1.4, b = 0.75
                scores[index] += idf * tf * (k1 + 1) / (tf + k1 * (1 - b + b * Double(chunk.length) / max(average, 1)))
            }
        }

        let ranked = chunks.indices.filter { scores[$0] > 0 }.sorted { scores[$0] > scores[$1] }
        var picked: [ChatChunk] = []
        var used = 0
        for index in ranked {
            let chunk = chunks[index]
            if used + chunk.text.count > budget, !picked.isEmpty { break }
            picked.append(chunk)
            used += chunk.text.count
            if picked.count >= 10 { break }
        }
        return picked
    }

    /// With nothing matching ("what happened this week?"), the newest summaries and notes are the context.
    static func recent(from chunks: [ChatChunk], budget: Int = 4500) -> [ChatChunk] {
        var picked: [ChatChunk] = []
        var used = 0
        for chunk in chunks.sorted(by: { $0.date > $1.date }) {
            if used + chunk.text.count > budget, !picked.isEmpty { break }
            picked.append(chunk)
            used += chunk.text.count
            if picked.count >= 8 { break }
        }
        return picked
    }
}

struct ChatSource: Identifiable, Hashable {
    let noteID: UUID
    let title: String
    let date: Date
    var id: UUID { noteID }
}

struct ChatMessage: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
    var sources: [ChatSource] = []
    var isError = false
}

/// The conversation with the notes. Kept while the app runs.
@MainActor
@Observable
final class ChatStore {
    private(set) var messages: [ChatMessage] = []
    private(set) var isThinking = false
    private(set) var status = ""

    @ObservationIgnored private var usedLocalModel = false
    @ObservationIgnored private var chunks: [ChatChunk] = []
    @ObservationIgnored private var signature = ""

    func reset() {
        guard !isThinking else { return }
        messages = []
    }

    /// Frees the model's memory again (when the chat is closed).
    func release() {
        guard !isThinking, usedLocalModel else { return }
        usedLocalModel = false
        Task { await ModelManager.shared.releaseLLM() }
    }

    func ask(_ question: String, notes: [Note]) async {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking else { return }
        let history = messages.suffix(4)
        messages.append(ChatMessage(role: .user, text: question))
        isThinking = true
        status = "Searching your notes …"
        defer {
            isThinking = false
            status = ""
        }

        let current = notes.filter { !$0.isDeleted }
        let newSignature = "\(current.count)-\(current.map { $0.updatedAt.timeIntervalSince1970 + Double($0.summary?.count ?? 0) }.reduce(0, +))"
        if newSignature != signature {
            chunks = ChatRetrieval.chunks(from: current)
            signature = newSignature
        }
        var context = ChatRetrieval.search(question, in: chunks)
        if context.isEmpty { context = ChatRetrieval.recent(from: chunks) }
        guard !context.isEmpty else {
            messages.append(ChatMessage(role: .assistant, text: "There is nothing in your notes yet."))
            return
        }

        do {
            usedLocalModel = AppSettings.billing == .local
            let text = try await Self.complete(question: question, history: Array(history), context: context) { [weak self] status in
                self?.status = status
            }
            messages.append(ChatMessage(role: .assistant, text: text, sources: Self.sources(in: text, context: context)))
        } catch {
            var message = ChatMessage(role: .assistant, text: error.localizedDescription)
            message.isError = true
            messages.append(message)
        }
    }

    /// The notes behind the passages the answer quotes as [n]; the best matches when it quotes none.
    private static func sources(in answer: String, context: [ChatChunk]) -> [ChatSource] {
        var numbers: [Int] = []
        var rest = Substring(answer)
        while let open = rest.firstIndex(of: "[") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "]") else { break }
            numbers += rest[afterOpen..<close].split(whereSeparator: { ", ".contains($0) }).compactMap { Int($0) }
            rest = rest[rest.index(after: close)...]
        }
        var indices = numbers.compactMap { $0 >= 1 && $0 <= context.count ? $0 - 1 : nil }
        if indices.isEmpty { indices = Array(context.indices.prefix(3)) }
        var seen = Set<UUID>()
        return indices.compactMap { index in
            let chunk = context[index]
            guard seen.insert(chunk.noteID).inserted else { return nil }
            return ChatSource(noteID: chunk.noteID, title: chunk.title, date: chunk.date)
        }
    }

    private static func complete(question: String, history: [ChatMessage], context: [ChatChunk], progress: @escaping (String) -> Void) async throws -> String {
        let system = """
        You are the assistant of a private notes app. Answer the question using only the excerpts from the user's notes and meeting transcripts below.
        Every excerpt starts with a number in brackets. Name the numbers of the excerpts you used, like [2].
        If the excerpts do not contain the answer, say so briefly. Answer in the language of the question and be concise.
        """
        var user = ""
        if !history.isEmpty {
            user += "Conversation so far:\n"
            for message in history {
                user += (message.role == .user ? "User: " : "Assistant: ") + String(message.text.prefix(500)) + "\n"
            }
            user += "\n"
        }
        user += "Excerpts:\n"
        for (index, chunk) in context.enumerated() {
            user += "[\(index + 1)] «\(chunk.title)» (\(chunk.date.formatted(date: .abbreviated, time: .omitted)))\n\(chunk.text)\n\n"
        }
        user += "Question: \(question)"

        switch AppSettings.billing {
        case .local:
            let local = LocalModel.selected
            ModelManager.shared.beginLLMUse()
            defer { ModelManager.shared.endLLMUse() }
            let installed = local.isInstalled
            progress(installed ? "Loading model …" : "Downloading model …")
            try await ModelManager.shared.ensureLLM(local) { fraction in
                // Loading an installed model reports progress too: only a missing one is downloaded.
                progress(!installed && fraction < 1 ? "Downloading model … \(Int(fraction * 100)) %" : "Loading model …")
            }
            progress("Thinking …")
            return try await LocalLLM.shared.generate(model: local, system: system, user: user, maxTokens: 700)
        case .byok:
            let provider = AIProvider.current
            let key = provider.apiKey
            if provider.requiresKey, key.isEmpty { throw SummaryError.missingAPIKey(provider.label) }
            progress("Thinking …")
            return try await CloudLLM.complete(provider: provider, apiKey: key, model: provider.model, system: system, user: user)
        }
    }
}
