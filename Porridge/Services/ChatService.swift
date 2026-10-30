import Foundation
import NaturalLanguage
import Observation

extension ChatRetrieval {
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

    func ask(_ question: String, notes: [Note], items: [ActionItem] = []) async {
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

        let index = NoteIndex.shared
        await index.refresh(notes)
        // The tasks and decisions always go along: "what is still open?" needs the list, not passages.
        let tasks = ActionItems.contextBlock(items: items, notes: notes, limit: 2200)
        var context = await index.search(question, budget: 6500 - tasks.count)
        if context.isEmpty { context = index.recent(budget: 4500 - tasks.count) }
        guard !context.isEmpty else {
            messages.append(ChatMessage(role: .assistant, text: "There is nothing in your notes yet."))
            return
        }

        do {
            usedLocalModel = AppSettings.billing == .local
            let text = try await Self.complete(question: question, history: Array(history), context: context, tasks: tasks) { [weak self] status in
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

    private static func complete(question: String, history: [ChatMessage], context: [ChatChunk], tasks: String, progress: @escaping (String) -> Void) async throws -> String {
        let system = """
        You are the assistant of a private notes app. Answer the question using only the excerpts from the user's notes and meeting transcripts below\(tasks.isEmpty ? "" : ", and the list of tasks and decisions taken from their summaries").
        Every excerpt starts with a number in brackets. Name the numbers of the excerpts you used, like [2].\(tasks.isEmpty ? "" : " For a task or decision name the note it comes from.")
        If the excerpts do not contain the answer, say so briefly. Answer in the language of the question and be concise.
        """
        var user = tasks
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
