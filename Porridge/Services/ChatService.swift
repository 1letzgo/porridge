import Foundation
import Observation
import SwiftData

extension ChatRetrieval {
    private static func chunk(_ note: Note, text: String, part: ChatChunk.Part, date: Date? = nil) -> ChatChunk {
        let words = tokens(note.displayTitle + " " + note.tags.joined(separator: " ") + " " + text)
        var frequencies: [String: Int] = [:]
        var prefixes: [String: Int] = [:]
        for word in words {
            frequencies[word, default: 0] += 1
            if let key = prefix(word) { prefixes[key, default: 0] += 1 }
        }
        return ChatChunk(
            noteID: note.id, title: note.displayTitle, date: date ?? note.createdAt, text: text,
            frequencies: frequencies, prefixFrequencies: prefixes, length: max(words.count, 1), part: part
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

    /// "To-do, open, due 12 December 2026, overdue, 1 of 3 subtasks done: Pack" or "To-do, done on 19 Nov 2026: Pack".
    static func todoLine(_ note: Note, now: Date = Date(), calendar: Calendar = .current) -> String {
        var head = "To-do, " + (note.isDone ? "done" : "open")
        if note.isDone, let at = note.todoDoneAt { head += " on " + at.formatted(.dateTime.day().month(.abbreviated).year()) }
        if let due = note.todoDue {
            head += ", due " + Todos.dueText(due)
            if !note.isDone, Todos.dueStatus(due, now: now, calendar: calendar) == .overdue { head += ", overdue" }
        }
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
            defer { if result.count == before, !note.title.isEmpty { result.append(chunk(note, text: note.displayTitle, part: .title)) } }
            // A saved link is found by its address and site, even when its page could not be read.
            if let url = note.url, !url.isEmpty {
                result.append(chunk(note, text: "Saved link" + (note.domain.map { " (\($0))" } ?? "") + ": " + url, part: .link))
            }
            // An image or a file is found by its name, even when nothing could be read out of it.
            let attachments = note.attachmentsData == nil ? [] : note.attachments
            if !attachments.isEmpty {
                result.append(chunk(note, text: (note.isImage ? "Image: " : "File: ") + attachments.map(\.name).joined(separator: ", "), part: .files))
            }
            // A to-do says so, and whether it is done: "what is still open?" finds it.
            if note.isTodo {
                // Dated by its due day: "what is due this week" looks at the passages of that time.
                result.append(chunk(note, text: todoLine(note), part: .todo, date: note.todoDue.flatMap { Todos.dueDate($0) }))
            }
            if let summary = note.summary, !summary.isEmpty {
                for piece in pieces(summary.components(separatedBy: "\n")) {
                    result.append(chunk(note, text: "Summary: " + piece, part: .summary))
                }
            }
            for piece in pieces(note.text.components(separatedBy: "\n")) {
                result.append(chunk(note, text: piece, part: .text))
            }
            if let page = note.pageText, !page.isEmpty {
                // What the passage is from: the page of a link, or what was read out of an image or a file.
                let label = note.isLink ? "Article" + (note.domain.map { " (\($0))" } ?? "") : note.isImage ? "Text in the image" : "Text of the file"
                for piece in pieces(page.components(separatedBy: "\n")) {
                    result.append(chunk(note, text: label + ": " + piece, part: .page))
                }
            }
            let speakers = note.speakers
            let lines = note.segments.map { segment -> String in
                let name = segment.speakerId.flatMap { id in speakers.first { $0.id == id }?.name }
                return (name.map { $0 + ": " } ?? "") + segment.text
            }
            for piece in pieces(lines) {
                result.append(chunk(note, text: "Transcript: " + piece, part: .transcript))
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

    /// The notes a chat is about: all living ones, or those of its bowl.
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
        // The bowls by name: a question may name one, and every entry says where it is filed.
        let names = Dictionary(projects.map { (Projects.key($0), $0.name) }, uniquingKeysWith: { first, _ in first })
        // The model chosen for the chat ("Chat Model"), else the default; its room decides how much context it gets.
        let model = SummaryModel.chat
        let found = await index.context(for: question, within: within, bucketNames: names, budget: .for(model))
        guard !found.isEmpty || found.matched != nil else {
            answer(thread.projectID == nil ? "There is nothing in your notes yet." : "There is nothing in this bowl yet.")
            return
        }

        do {
            if case .local = model { usedLocalModel = true }
            let text = try await Self.complete(
                question: question, history: history, context: found,
                bucket: thread.projectID.flatMap { names[$0] }, model: model
            ) { [weak self] status in
                self?.status = status
            }
            answer(text, sources: Self.sources(in: text, items: found.items, wordsNotFound: found.wordsNotFound))
        } catch {
            answer(Self.message(for: error, model: model), isError: true)
        }
    }

    /// An error as the chat says it: what went wrong with which service, and what to do.
    static func message(for error: Error, model: SummaryModel) -> String {
        if let error = error as? URLError {
            var place = model.place
            if case .cloud(.custom, _) = model { place = "your server" }
            switch error.code {
            case .timedOut: return "\(place.prefix(1).uppercased() + place.dropFirst()) took too long to answer. Try again in a moment."
            case .cancelled: return "The question was cancelled."
            default: return "Could not reach \(place). Check the internet connection and try again."
            }
        }
        return error.localizedDescription
    }

    /// The notes behind the items the answer quotes as [n]; without a number, the first passages (not the list of
    /// matches, which may be long).
    static func sources(in answer: String, items: [ChatContextItem], wordsNotFound: Bool = false) -> [ChatSource] {
        var numbers: [Int] = []
        var rest = Substring(answer)
        while let open = rest.firstIndex(of: "[") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "]") else { break }
            numbers += rest[afterOpen..<close].split(whereSeparator: { ", ".contains($0) }).compactMap { Int($0) }
            rest = rest[rest.index(after: close)...]
        }
        var indices = numbers.compactMap { $0 >= 1 && $0 <= items.count ? $0 - 1 : nil }
        // An answer without numbers gets the first passages that fit, never the stand-ins: entries outside the
        // filters, or the newest ones offered because nothing had the question's words ("nothing found").
        if indices.isEmpty, !wordsNotFound {
            let passages = items.indices.filter { !items[$0].isListing && !items[$0].isOutside }
            let listed = items.indices.filter { items[$0].isListing }
            indices = Array((passages.isEmpty ? listed : passages).prefix(3))
        }
        var seen = Set<UUID>()
        return indices.compactMap { index in
            let item = items[index]
            guard seen.insert(item.noteID).inserted else { return nil }
            return ChatSource(noteID: item.noteID, title: item.title, date: item.date)
        }
    }

    static let noModel = "No model is ready for the chat. Download or add one in Settings, under AI."

    /// What the model is told and asked. `limit` cuts the context for a model with little room: the list of
    /// matches first (the model is told how many were left out), then the passages, the best first.
    static func prompt(
        question: String, history: [(role: ChatEntry.Role, text: String)], context: ChatContext,
        bucket: String?, limit: Int = .max, now: Date = Date()
    ) -> (system: String, user: String) {
        let system = """
        Today is \(now.formatted(date: .complete, time: .omitted)) (\(ChatDocument.dayText(now))).
        You are the assistant of a private notes app. Answer the question only from the entries and excerpts below; do not use outside knowledge and do not guess. They are taken from the user's notes, meetings (transcripts and summaries), to-dos, saved web links (with the text of the page), images and files (with the text read out of them)\(bucket.map { ", all of them filed in the bowl \"\($0)\"" } ?? "").
        Every item starts with a number in brackets and a header: «title» — kind (for a to-do its state, due day and subtasks), the day it was created, its bowl (or Inbox), tags, and for a link its address. Use the header for questions about kind, dates, bowls and to-dos.
        When a list of matching entries is given, it holds every entry of the kind, bowl, to-do state or time the question asks for: answer list questions from it in full and add nothing that is not in it. When the question also names a topic, take those entries of the list that are about it (they come first and say what they mention).
        Write the answer itself in full words: name every entry you mention by its title and give the facts the question asks for (for a to-do its due day, for a link its address, for a meeting what was said or decided). Put the numbers of the items you used after the facts, like: Hecke schneiden, due 22 November [2]. Never answer with numbers alone.
        If the items do not contain the answer, say plainly that you found nothing about it in the notes.
        Always answer in the language the question is written in (a German question gets a German answer). Be concise.
        """
        var user = ""
        if !history.isEmpty {
            user += "Conversation so far:\n"
            for message in history {
                user += (message.role == .user ? "User: " : "Assistant: ") + String(message.text.prefix(500)) + "\n"
            }
            user += "\n"
        }
        let items = context.items
        var number = 0
        if let matched = context.matched {
            let listing = items.filter(\.isListing)
            var lines: [String] = []
            var size = user.count
            for item in listing {
                let line = "[\(number + 1)] \(item.header)" + (item.text.isEmpty ? "" : "\n    " + item.text)
                if size + line.count > limit / 2, !lines.isEmpty { break }
                lines.append(line)
                size += line.count + 1
                number += 1
            }
            if matched == 0 {
                user += "No entry matches (\(context.filter)).\n\n"
            } else {
                let shown = lines.count < matched ? "the first \(lines.count) of \(matched) entries" : "all \(matched) entr\(matched == 1 ? "y" : "ies")"
                user += "Matching entries (\(context.filter)): \(shown).\n" + lines.joined(separator: "\n") + "\n\n"
            }
            // The items not shown keep their numbers out of the prompt: the rest counts on from here.
            number = listing.count
        }
        let inside = items.filter { !$0.isListing && !$0.isOutside }
        let outside = items.filter(\.isOutside)
        func block(_ title: String, _ list: [ChatContextItem], start: Int) {
            guard !list.isEmpty else { return }
            user += title + "\n"
            for (offset, item) in list.enumerated() {
                if user.count + item.text.count > limit, offset > 0 { break }
                user += "[\(start + offset + 1)] \(item.header)\n\(item.text)\n\n"
            }
        }
        let plain = context.wordsNotFound ? "No entry contains the words of the question. The newest entries, only in case they answer it:" : "Excerpts:"
        block(context.matched == nil ? plain : "Excerpts from the matching entries:", inside, start: number)
        block(context.matched == nil ? "Excerpts:" : "Excerpts from other entries (they do not match \(context.filter); use them only if they answer the question):", outside, start: number + inside.count)
        user += "Question: \(question)"
        return (system, user)
    }

    private static func complete(
        question: String, history: [(role: ChatEntry.Role, text: String)], context: ChatContext,
        bucket: String?, model: SummaryModel, progress: @escaping (String) -> Void
    ) async throws -> String {
        switch model {
        case .local(let local):
            // The Apple model has room for far fewer excerpts.
            let prompt = prompt(question: question, history: history, context: context, bucket: bucket, limit: ChatBudget.for(model).promptLimit)
            // A question never starts a download of gigabytes on its own: the model is fetched in Settings.
            guard local.isInstalled else { throw SummaryError.provider(Self.noModel) }
            ModelManager.shared.beginLLMUse()
            defer { ModelManager.shared.endLLMUse() }
            progress("Loading model…")
            try await ModelManager.shared.ensureLLM(local) { _ in }
            progress("Thinking…")
            return try await LocalLLM.shared.generate(model: local, system: prompt.system, user: prompt.user, maxTokens: 700)
        case .cloud(let provider, let id):
            let prompt = prompt(question: question, history: history, context: context, bucket: bucket, limit: ChatBudget.for(model).promptLimit)
            let key = provider.apiKey
            if provider.requiresKey, key.isEmpty { throw SummaryError.missingAPIKey(provider.label) }
            progress("Thinking…")
            return try await CloudLLM.complete(provider: provider, apiKey: key, model: id, system: prompt.system, user: prompt.user)
        }
    }
}
