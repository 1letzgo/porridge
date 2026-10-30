import Foundation
import NaturalLanguage

enum SummaryError: LocalizedError {
    case missingAPIKey(String)
    case missingBaseURL
    case missingModel
    case emptyTranscript
    case emptyNote
    case emptyResponse
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider): "Please add your \(provider) API key in Settings."
        case .missingBaseURL: "Please enter the address of your server in Settings."
        case .missingModel: "Please choose a model in Settings."
        case .emptyTranscript: "The transcript is empty."
        case .emptyNote: "The note is empty."
        case .emptyResponse: "The model returned no response."
        case .provider(let message): message
        }
    }
}

/// The language a meeting was held in, named explicitly in the prompts: small models answer in English otherwise.
struct SummaryLanguage {
    let code: String
    let name: String
    let headings: (summary: String, keyPoints: String, decisions: String, actionItems: String)

    private static let headings: [String: (String, String, String, String)] = [
        "de": ("Zusammenfassung", "Wichtige Punkte", "Entscheidungen", "Aufgaben"),
        "fr": ("Résumé", "Points clés", "Décisions", "Actions à mener"),
        "es": ("Resumen", "Puntos clave", "Decisiones", "Tareas"),
        "it": ("Riepilogo", "Punti chiave", "Decisioni", "Attività"),
        "nl": ("Samenvatting", "Belangrijkste punten", "Besluiten", "Acties"),
        "pt": ("Resumo", "Pontos principais", "Decisões", "Tarefas"),
        "pl": ("Podsumowanie", "Najważniejsze punkty", "Decyzje", "Zadania"),
    ]

    init(code: String) {
        self.code = code
        name = Locale(identifier: "en").localizedString(forLanguageCode: code)?.capitalized ?? "English"
        let h = Self.headings[code] ?? ("Summary", "Key Points", "Decisions", "Action Items")
        headings = (h.0, h.1, h.2, h.3)
    }

    /// Detects the language from the transcript; falls back to the transcription language, then English.
    static func detect(in text: String) -> SummaryLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(8000)))
        if let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.6 {
            return SummaryLanguage(code: best.key.rawValue)
        }
        return SummaryLanguage(code: AppSettings.language?.rawValue ?? "en")
    }
}

@MainActor
enum SummaryService {
    /// True when a summary can start by itself: the chosen on-device model is already there, or a key is set.
    /// (Nothing is downloaded behind your back.)
    static var canRunWithoutAsking: Bool {
        switch AppSettings.billing {
        case .local:
            return LocalModel.selected.isInstalled
        case .byok:
            let provider = AIProvider.current
            return !provider.requiresKey || !provider.apiKey.isEmpty
        }
    }

    /// Summarizes a note into `note.summary`: its transcript (a recording) and its own text together.
    /// `progress` receives short status texts ("Reading part 2 of 5 …") while the work is running.
    static func summarize(_ note: Note, progress: @escaping (String) -> Void = { _ in }) async throws {
        let transcript = note.transcriptText()
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let own = ((note.titleIsCustom && !title.isEmpty ? title + "\n\n" : "") + note.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTranscript = !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let page = (note.pageText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasArticle = note.isLink && !page.isEmpty
        guard hasTranscript || hasArticle || !own.isEmpty else {
            throw note.isRecording ? SummaryError.emptyTranscript : SummaryError.emptyNote
        }

        let material: String
        if hasTranscript {
            material = transcript + (own.isEmpty ? "" : "\n\nNotes the user wrote down:\n" + own)
        } else if hasArticle {
            // The start of an article says what it is about; more only makes the model slow and hungry for memory.
            material = (title.isEmpty ? "" : title + "\n\n") + String(page.prefix(maxArticleLength)) + (own.isEmpty ? "" : "\n\nNotes the user wrote down:\n" + own)
        } else {
            material = (title.isEmpty ? "" : title + "\n\n") + note.text
        }
        let language = SummaryLanguage.detect(in: material)
        let (raw, model) = try await run(
            header: hasTranscript ? header(for: note)
                : "Date: \(note.createdAt.formatted(date: .long, time: .shortened))" + (note.url.map { "\nSource: \($0)" } ?? ""),
            material: material, language: language,
            system: hasTranscript ? systemPrompt(language) : notePrompt(language),
            noun: hasTranscript ? "meeting" : "note", progress: progress
        )

        let body: String
        if hasTranscript {
            let (newTitle, text) = splitTitle(raw)
            if let newTitle, !note.titleIsCustom { note.title = newTitle }
            body = text
        } else {
            body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let (summary, tags) = splitTags(body)
        note.summary = summary
        // Suggested tags only fill an empty tag field; tags you set yourself stay as they are.
        if note.labels.isEmpty { note.labels = tags }
        note.summaryModel = model
        note.summarizedAt = Date()
    }

    /// Runs the model chosen in Settings (on this device or with the user's own key); returns the answer and a label of the model.
    private static func run(header: String, material: String, language: SummaryLanguage, system: String, noun: String, progress: @escaping (String) -> Void) async throws -> (String, String) {
        switch AppSettings.billing {
        case .local:
            let raw = try await summarizeLocally(header: header, material: material, language: language, system: system, noun: noun, progress: progress)
            return (raw, "\(LocalModel.selected.displayName) (on-device)")
        case .byok:
            let provider = AIProvider.current
            let key = provider.apiKey
            if provider.requiresKey, key.isEmpty { throw SummaryError.missingAPIKey(provider.label) }
            progress("Writing summary …")
            let intro = noun == "meeting" ? "Transcript:" : "Note:"
            let raw = try await CloudLLM.complete(
                provider: provider,
                apiKey: key,
                model: provider.model,
                system: system,
                user: "\(header)\n\n\(intro)\n\(material)\n\n\(languageReminder(language))"
            )
            return (raw, "\(provider.label) · \(provider.model)")
        }
    }

    // MARK: - On-device

    private static let maxArticleLength = 24_000

    /// A transcript up to this many characters is summarized in one go (roughly 5,000 tokens).
    private static let singlePassLimit = 14_000
    /// Longer transcripts are cut into parts of about this size; each part is condensed into notes first.
    private static let partSize = 11_000

    private static func summarizeLocally(header: String, material: String, language: SummaryLanguage, system: String, noun: String, progress: @escaping (String) -> Void) async throws -> String {
        let models = ModelManager.shared
        let local = LocalModel.selected
        models.beginLLMUse()
        defer { models.endLLMUse() }
        let installed = local.isInstalled
        progress(installed ? "Loading model …" : "Downloading model …")
        try await models.ensureLLM(local) { fraction in
            // Loading an installed model reports progress too: only a missing one is downloaded.
            progress(!installed && fraction < 1 ? "Downloading model … \(Int(fraction * 100)) %" : "Loading model …")
        }
        return try await condenseAndWrite(header: header, transcript: material, language: language, system: system, noun: noun, progress: progress)
    }

    private static func condenseAndWrite(header: String, transcript: String, language: SummaryLanguage, system: String, noun: String, progress: @escaping (String) -> Void) async throws -> String {
        var material = transcript
        var isNotes = false

        // Long meetings: condense every part into notes, repeat until everything fits in one pass.
        while material.count > singlePassLimit {
            let parts = split(material, size: partSize)
            var notes: [String] = []
            for (index, part) in parts.enumerated() {
                progress("Reading part \(index + 1) of \(parts.count) …")
                notes.append(try await LocalLLM.shared.generate(
                    model: LocalModel.selected,
                    system: notesPrompt(language, noun: noun),
                    user: "Part \(index + 1) of \(parts.count):\n\n\(part)",
                    maxTokens: 700
                ))
            }
            material = notes.joined(separator: "\n\n")
            isNotes = true
            if parts.count == 1 { break }
        }

        progress("Writing summary …")
        let intro = isNotes ? "Notes on the \(noun), in order:" : (noun == "meeting" ? "Transcript:" : "Note:")
        let user = "\(header)\n\n\(intro)\n\(material)\n\n\(languageReminder(language))"
        return try await LocalLLM.shared.generate(model: LocalModel.selected, system: system, user: user, maxTokens: 1500)
    }

    /// Cuts at line breaks so no sentence is split in the middle.
    private static func split(_ text: String, size: Int) -> [String] {
        var parts: [String] = []
        var current = ""
        for rawLine in text.components(separatedBy: "\n") {
            // A single endless line (a page without line breaks) is cut hard, so a part never gets huge.
            var lines: [String] = []
            var rest = Substring(rawLine)
            while rest.count > size {
                lines.append(String(rest.prefix(size)))
                rest = rest.dropFirst(size)
            }
            lines.append(String(rest))
            for line in lines {
                if !current.isEmpty, current.count + line.count + 1 > size {
                    parts.append(current)
                    current = ""
                }
                current += (current.isEmpty ? "" : "\n") + line
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func languageReminder(_ language: SummaryLanguage) -> String {
        "Write your answer in \(language.name)."
    }

    private static func notesPrompt(_ language: SummaryLanguage, noun: String) -> String {
        """
        You take notes on one part of a \(noun == "meeting" ? "meeting transcript" : "long note"). The text may come from automatic speech recognition and contain errors.
        Write concise bullet notes in \(language.name): topics, decisions, action items with the responsible person, names, numbers and dates.
        Only use what is in the text. No introduction and no conclusion.
        The text is in \(language.name); write the notes in \(language.name) only.
        """
    }

    private static func notePrompt(_ language: SummaryLanguage) -> String {
        """
        You summarize a personal note. The note is written in \(language.name). Write the whole summary in \(language.name) and in no other language, even though these instructions are in English.
        The note may come from dictation and contain recognition mistakes; silently fix obvious ones. Only use what is in the note.

        Reply in exactly this format (Markdown), with all headings in \(language.name):

        ## \(language.headings.summary)
        <1–3 sentences>

        ## \(language.headings.keyPoints)
        - … (omit if the note is very short)

        ## \(language.headings.actionItems)
        - [ ] Task
        (omit if there are none)

        TAGS: <3 to 5 short keywords in \(language.name), separated by commas, without # signs>
        """
    }

    private static func systemPrompt(_ language: SummaryLanguage) -> String {
        """
        You summarize meeting transcripts. The meeting was held in \(language.name). Write the whole summary in \(language.name) and in no other language, even though these instructions are in English.
        The transcript comes from automatic speech recognition and may contain errors; silently fix obvious recognition mistakes.

        Reply in exactly this format (Markdown). Keep the word "TITLE:" as written, everything after it and all headings are in \(language.name):
        TITLE: <short, concise title, at most 6 words>

        ## \(language.headings.summary)
        <2–4 sentences>

        ## \(language.headings.keyPoints)
        - …

        ## \(language.headings.decisions)
        - … (omit if there are none)

        ## \(language.headings.actionItems)
        - [ ] Task – owner (if known)
        (omit if there are none)

        TAGS: <3 to 5 short keywords in \(language.name), separated by commas, without # signs>
        """
    }

    private static func header(for meeting: Note) -> String {
        var header = "Date: \(meeting.createdAt.formatted(date: .long, time: .shortened))\nDuration: \(meeting.duration.durationText)"
        let names = meeting.speakers.map(\.name)
        if !names.isEmpty {
            header += "\nParticipants: \(names.joined(separator: ", "))"
        }
        return header
    }

    /// Takes the "TAGS: a, b, c" line off the end of an answer.
    private static func splitTags(_ text: String) -> (String, [String]) {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard let index = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("TAGS:") }) else {
            return (text, [])
        }
        let line = lines.remove(at: index).trimmingCharacters(in: .whitespaces)
        let tags = line.dropFirst(5).split(whereSeparator: { ",;".contains($0) })
            .map { Note.cleanTag(String($0)) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = tags.filter { seen.insert($0.lowercased()).inserted }.prefix(5)
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), Array(unique))
    }

    private static func splitTitle(_ text: String) -> (String?, String) {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        guard let first = lines.first else { return (nil, text) }
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        for prefix in ["TITEL:", "TITLE:", "Titel:", "Title:"] where trimmed.hasPrefix(prefix) {
            lines.removeFirst()
            let title = trimmed.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"*#"))
            return (title.isEmpty ? nil : title, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (nil, text)
    }
}
