import Foundation
import Observation
import SwiftData

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

    /// "To-do, open, 1 of 3 subtasks done: Pack" or "To-do, done on 19 Nov 2026: Pack".
    static func todoLine(_ note: Note) -> String {
        var head = "To-do, " + (note.isDone ? "done" : "open")
        if note.isDone, let at = note.todoDoneAt { head += " on " + at.formatted(.dateTime.day().month(.abbreviated).year()) }
        let progress = note.todoProgress
        if progress.total > 0 { head += ", \(progress.done) of \(progress.total) subtasks done" }
        return head + ": " + note.displayTitle
    }

    /// Everything a note holds, cut into passages: its own text, its summary, the page of a link, the text read out
    /// of an image or a file, and the transcript of a meeting. Whatever comes in is read into the index this way.
    static func chunks(from notes: [Note]) -> [ChatChunk] {
        var result: [ChatChunk] = []
        for note in notes where !note.isDeleted {
            let before = result.count
            // With nothing but a title, the title is the passage: the note is still there to be found.
            defer { if result.count == before, !note.title.isEmpty { result.append(chunk(note, text: note.displayTitle)) } }
            // A saved link is found by its address and site, even when its page could not be read.
            if let url = note.url, !url.isEmpty {
                result.append(chunk(note, text: "Saved link" + (note.domain.map { " (\($0))" } ?? "") + ": " + url))
            }
            // An image or a file is found by its name, even when nothing could be read out of it.
            let attachments = note.attachmentsData == nil ? [] : note.attachments
            if !attachments.isEmpty {
                result.append(chunk(note, text: (note.isImage ? "Image: " : "File: ") + attachments.map(\.name).joined(separator: ", ")))
            }
            // A to-do says so, and whether it is done: "what is still open?" finds it.
            if note.isTodo {
                result.append(chunk(note, text: todoLine(note)))
            }
            if let summary = note.summary, !summary.isEmpty {
                for piece in pieces(summary.components(separatedBy: "\n")) {
                    result.append(chunk(note, text: "Summary: " + piece))
                }
            }
            for piece in pieces(note.text.components(separatedBy: "\n")) {
                result.append(chunk(note, text: piece))
            }
            if let page = note.pageText, !page.isEmpty {
                // What the passage is from: the page of a link, or what was read out of an image or a file.
                let label = note.isLink ? "Article" + (note.domain.map { " (\($0))" } ?? "") : note.isImage ? "Text in the image" : "Text of the file"
                for piece in pieces(page.components(separatedBy: "\n")) {
                    result.append(chunk(note, text: label + ": " + piece))
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

/// Asks the notes: finds the passages that fit a question (`NoteIndex`), has the model chosen in Settings answer
/// from them, and keeps question and answer in their chat (`ChatThread`, `ChatEntry`).
@MainActor
@Observable
final class ChatService {
    static let shared = ChatService()

    /// The chat that is being answered right now.
    private(set) var thinking: UUID?
    private(set) var status = ""

    @ObservationIgnored private var usedLocalModel = false

    /// Frees the model's memory again (when the chat is closed).
    func release() {
        guard thinking == nil, usedLocalModel else { return }
        usedLocalModel = false
        Task { await ModelManager.shared.releaseLLM() }
    }

    /// The notes a chat is about: all living ones, or those of its bucket.
    static func scope(of thread: ChatThread, notes: [Note]) -> [Note] {
        let living = notes.filter { !$0.isDeleted }
        guard let project = thread.projectID else { return living }
        return living.filter { $0.projectIDs.contains(project) }
    }

    /// A title for a chat from its first question.
    static func title(for question: String) -> String {
        let line = question.split(whereSeparator: \.isNewline).first.map(String.init) ?? question
        return line.count > 60 ? String(line.prefix(57)).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    func ask(_ question: String, in thread: ChatThread, notes: [Note], projects: [NoteFolder], context: ModelContext) async {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, thinking == nil else { return }
        let threadID = thread.id
        let earlier = (try? context.fetch(FetchDescriptor<ChatEntry>(
            predicate: #Predicate { $0.threadID == threadID }, sortBy: [SortDescriptor(\.createdAt)]
        ))) ?? []
        let history = earlier.filter { !$0.isError }.suffix(4).map { (role: $0.role, text: $0.text) }
        if thread.title.isEmpty { thread.title = Self.title(for: question) }
        thread.updatedAt = Date()
        context.insert(ChatEntry(threadID: threadID, role: .user, text: question))
        try? context.save()

        thinking = threadID
        status = "Searching your notes…"
        defer {
            thinking = nil
            status = ""
        }

        func answer(_ text: String, sources: [ChatSource] = [], isError: Bool = false) {
            // The chat was deleted while the model was working: there is nothing to write to.
            guard thread.modelContext != nil else { return }
            let entry = ChatEntry(threadID: threadID, role: .assistant, text: text, isError: isError)
            entry.sources = sources
            context.insert(entry)
            thread.updatedAt = Date()
            try? context.save()
        }

        // Whatever came in since the last look is read into the index first.
        let index = NoteIndex.shared
        await index.refresh(notes)
        let scope = Self.scope(of: thread, notes: notes)
        let within = thread.projectID == nil ? nil : Set(scope.map(\.id))
        let passages = await index.search(question, within: within)
        guard !passages.isEmpty else {
            answer(thread.projectID == nil ? "There is nothing in your notes yet." : "There is nothing in this bucket yet.")
            return
        }

        // Which buckets a passage's note is in: the model may be asked about a bucket by name.
        let names = Dictionary(projects.map { (Projects.key($0), $0.name) }, uniquingKeysWith: { first, _ in first })
        let buckets = Dictionary(scope.map { note in (note.id, note.projectIDs.compactMap { names[$0] }) }, uniquingKeysWith: { first, _ in first })
        do {
            let model = SummaryModel.current
            if case .local = model { usedLocalModel = true }
            let text = try await Self.complete(
                question: question, history: history, passages: passages, buckets: buckets,
                bucket: thread.projectID.flatMap { names[$0] }, model: model
            ) { [weak self] status in
                self?.status = status
            }
            answer(text, sources: Self.sources(in: text, passages: passages))
        } catch {
            answer(error.localizedDescription, isError: true)
        }
    }

    /// The notes behind the passages the answer quotes as [n]; the best matches when it quotes none.
    static func sources(in answer: String, passages: [ChatChunk]) -> [ChatSource] {
        var numbers: [Int] = []
        var rest = Substring(answer)
        while let open = rest.firstIndex(of: "[") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "]") else { break }
            numbers += rest[afterOpen..<close].split(whereSeparator: { ", ".contains($0) }).compactMap { Int($0) }
            rest = rest[rest.index(after: close)...]
        }
        var indices = numbers.compactMap { $0 >= 1 && $0 <= passages.count ? $0 - 1 : nil }
        if indices.isEmpty { indices = Array(passages.indices.prefix(3)) }
        var seen = Set<UUID>()
        return indices.compactMap { index in
            let chunk = passages[index]
            guard seen.insert(chunk.noteID).inserted else { return nil }
            return ChatSource(noteID: chunk.noteID, title: chunk.title, date: chunk.date)
        }
    }

    static let noModel = "No model is ready for the chat. Download or add one in Settings, under AI."

    /// What the model is told and asked. `limit` cuts the excerpts for a model with little room; the best come first.
    static func prompt(
        question: String, history: [(role: ChatEntry.Role, text: String)], passages: [ChatChunk],
        buckets: [UUID: [String]], bucket: String?, limit: Int = .max, now: Date = Date()
    ) -> (system: String, user: String) {
        let system = """
        Today is \(now.formatted(date: .complete, time: .omitted)).
        You are the assistant of a private notes app. Answer the question using only the excerpts below. They are taken from the user's notes, meeting transcripts, saved web links (with the text of the page), images and files (with the text read out of them)\(bucket.map { ", all of them filed in the bucket \"\($0)\"" } ?? "").
        Every excerpt starts with a number in brackets, then the title of its note, its date and the buckets it is filed in. Name the numbers of the excerpts you used, like [2].
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
        for (index, chunk) in passages.enumerated() {
            if user.count + chunk.text.count > limit { break }
            let filed = buckets[chunk.noteID] ?? []
            let place = filed.isEmpty ? "Inbox" : filed.joined(separator: ", ")
            user += "[\(index + 1)] «\(chunk.title)» (\(chunk.date.formatted(date: .abbreviated, time: .omitted)), \(place))\n\(chunk.text)\n\n"
        }
        user += "Question: \(question)"
        return (system, user)
    }

    private static func complete(
        question: String, history: [(role: ChatEntry.Role, text: String)], passages: [ChatChunk],
        buckets: [UUID: [String]], bucket: String?, model: SummaryModel, progress: @escaping (String) -> Void
    ) async throws -> String {
        switch model {
        case .local(let local):
            // The Apple model has room for far fewer excerpts.
            let prompt = prompt(question: question, history: history, passages: passages, buckets: buckets, bucket: bucket, limit: local == .apple ? 7_000 : .max)
            // A question never starts a download of gigabytes on its own: the model is fetched in Settings.
            guard local.isInstalled else { throw SummaryError.provider(Self.noModel) }
            ModelManager.shared.beginLLMUse()
            defer { ModelManager.shared.endLLMUse() }
            progress("Loading model…")
            try await ModelManager.shared.ensureLLM(local) { _ in }
            progress("Thinking…")
            return try await LocalLLM.shared.generate(model: local, system: prompt.system, user: prompt.user, maxTokens: 700)
        case .cloud(let provider, let id):
            let prompt = prompt(question: question, history: history, passages: passages, buckets: buckets, bucket: bucket)
            let key = provider.apiKey
            if provider.requiresKey, key.isEmpty { throw SummaryError.missingAPIKey(provider.label) }
            progress("Thinking…")
            return try await CloudLLM.complete(provider: provider, apiKey: key, model: id, system: prompt.system, user: prompt.user)
        }
    }
}
