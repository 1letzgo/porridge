import Foundation

// MARK: - Presets

/// An instruction for rewriting a selection: one of the built-in ones ("Shorter", "Fix Spelling & Grammar") or
/// one the user saved from the prompt field.
struct RewritePreset: Codable, Identifiable, Equatable, Hashable {
    var id: String
    var title: String
    var instruction: String
    var systemImage: String

    /// The quick choices of the rewrite sheet, in this order.
    static let builtIn: [RewritePreset] = [
        RewritePreset(id: "improve", title: "Improve Writing", instruction: "Improve the writing: clearer, smoother sentences and better word choice. Keep the meaning, the facts and the tone.", systemImage: "wand.and.stars"),
        RewritePreset(id: "fix", title: "Fix Spelling & Grammar", instruction: "Fix spelling, grammar and punctuation only. Change nothing else.", systemImage: "textformat.abc"),
        RewritePreset(id: "shorter", title: "Shorter", instruction: "Make it shorter and more concise. Keep every important fact.", systemImage: "arrow.down.right.and.arrow.up.left"),
        RewritePreset(id: "longer", title: "Longer", instruction: "Make it longer: expand it with more detail and explanation, but do not invent facts.", systemImage: "arrow.up.left.and.arrow.down.right"),
        RewritePreset(id: "formal", title: "More Formal", instruction: "Make the tone more formal and professional.", systemImage: "briefcase"),
        RewritePreset(id: "casual", title: "More Casual", instruction: "Make the tone more casual and friendly.", systemImage: "face.smiling"),
        RewritePreset(id: "english", title: "Translate to English", instruction: "Translate it into English.", systemImage: "globe"),
        RewritePreset(id: "german", title: "Translate to German", instruction: "Translate it into German.", systemImage: "globe.europe.africa"),
        RewritePreset(id: "list", title: "Make a List", instruction: "Turn it into a Markdown bullet list (\"- \"), one point per item.", systemImage: "list.bullet"),
        RewritePreset(id: "summarize", title: "Summarize", instruction: "Summarize it in a few sentences.", systemImage: "text.append"),
    ]

    /// A preset of the user's own: named after its instruction.
    static func custom(_ instruction: String) -> RewritePreset {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = text.components(separatedBy: .newlines).first ?? text
        let title = line.count > 40 ? String(line.prefix(39)).trimmingCharacters(in: .whitespaces) + "…" : line
        return RewritePreset(id: "custom-\(UUID().uuidString)", title: title, instruction: text, systemImage: "bookmark")
    }
}

/// The presets the user saved, as JSON in the defaults and in iCloud key-value storage (where the app has it), so
/// they follow to the other devices. No CloudKit fields.
@MainActor
final class RewritePresetStore {
    static let shared = RewritePresetStore()
    static let key = "aiRewritePresets"

    private let defaults: UserDefaults
    private let cloud: NSUbiquitousKeyValueStore?

    init(defaults: UserDefaults = .standard, cloud: NSUbiquitousKeyValueStore? = .default) {
        self.defaults = defaults
        self.cloud = cloud
    }

    /// The saved presets, newest last. iCloud wins when it has a list (another device saved one).
    var presets: [RewritePreset] {
        get {
            if let data = cloud?.data(forKey: Self.key), let list = Self.decode(data) { return list }
            return defaults.data(forKey: Self.key).flatMap(Self.decode) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Self.key)
            cloud?.set(data, forKey: Self.key)
        }
    }

    static func decode(_ data: Data) -> [RewritePreset]? {
        try? JSONDecoder().decode([RewritePreset].self, from: data)
    }

    /// Saves an instruction; the same instruction twice is kept once. Returns the preset (the existing one when
    /// it was there already), nil for an empty instruction.
    @discardableResult
    func save(_ instruction: String) -> RewritePreset? {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var list = presets
        if let existing = list.first(where: { $0.instruction.caseInsensitiveCompare(text) == .orderedSame }) { return existing }
        let preset = RewritePreset.custom(text)
        list.append(preset)
        presets = list
        return preset
    }

    /// Takes a preset away; returns where it was, for undo.
    @discardableResult
    func remove(_ preset: RewritePreset) -> Int? {
        var list = presets
        guard let index = list.firstIndex(where: { $0.id == preset.id }) else { return nil }
        list.remove(at: index)
        presets = list
        return index
    }

    /// Puts a removed preset back where it was.
    func restore(_ preset: RewritePreset, at index: Int) {
        var list = presets
        guard !list.contains(where: { $0.id == preset.id }) else { return }
        list.insert(preset, at: min(max(0, index), list.count))
        presets = list
    }
}

// MARK: - The selection

/// What is rewritten: a piece of the note's Markdown, with the note as it was when it was chosen. Offsets count
/// characters (`Character`) of `markdown`.
struct RewriteTarget: Equatable {
    var markdown: String
    var range: Range<Int>

    var selected: String { RewriteEdit.substring(markdown, range) }
    /// Some text before and after, so the model knows what the passage is about (it is not rewritten).
    func context(limit: Int) -> (before: String, after: String) {
        guard limit > 0 else { return ("", "") }
        let before = RewriteEdit.substring(markdown, max(0, range.lowerBound - limit)..<range.lowerBound)
        let after = RewriteEdit.substring(markdown, range.upperBound..<min(markdown.count, range.upperBound + limit))
        return (before.trimmingCharacters(in: .whitespacesAndNewlines), after.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// A rewrite the editor is asked to show the sheet for.
struct RewriteRequest: Identifiable, Equatable {
    let id = UUID()
    var target: RewriteTarget
}

/// The Markdown side of a rewrite: which part of the note is sent, and how the answer goes back in. Kept apart
/// from the text view so the rules can be tested.
enum RewriteEdit {
    static func substring(_ text: String, _ range: Range<Int>) -> String {
        let lower = max(0, min(range.lowerBound, text.count))
        let upper = max(lower, min(range.upperBound, text.count))
        let start = text.index(text.startIndex, offsetBy: lower)
        let end = text.index(start, offsetBy: upper - lower)
        return String(text[start..<end])
    }

    /// The selection as it is rewritten: no blank space at its ends; across several lines, whole lines (with their
    /// marks: "- ", "## ", "- [ ] "); within one line, never inside the line's mark nor half of a `**bold**`,
    /// `*italic*`, `` `code` ``, link or `[[link]]`. Nil when nothing but blank space is selected.
    static func normalize(_ range: Range<Int>, in markdown: String) -> Range<Int>? {
        let chars = Array(markdown)
        var lower = max(0, min(range.lowerBound, chars.count))
        var upper = max(lower, min(range.upperBound, chars.count))
        while lower < upper, chars[lower].isWhitespace { lower += 1 }
        while upper > lower, chars[upper - 1].isWhitespace { upper -= 1 }
        guard lower < upper else { return nil }
        let first = lineBounds(of: lower, in: chars)
        let last = lineBounds(of: upper - 1, in: chars)
        if first.start != last.start {
            // Several lines: the whole lines.
            return first.start..<last.end
        }
        let markEnd = first.start + markLength(String(chars[first.start..<first.end]))
        lower = max(lower, markEnd)
        guard lower < upper else { return markEnd < first.end ? markEnd..<first.end : nil }
        // Spans of inline marks that the selection cuts are taken whole.
        let line = String(chars[first.start..<first.end])
        let spans = inlineSpans(in: line).map { ($0.lowerBound + first.start)..<($0.upperBound + first.start) }
        var changed = true
        while changed {
            changed = false
            for span in spans {
                let overlaps = span.lowerBound < upper && lower < span.upperBound
                let inside = span.lowerBound >= lower && span.upperBound <= upper
                if overlaps, !inside {
                    lower = min(lower, span.lowerBound)
                    upper = max(upper, span.upperBound)
                    changed = true
                }
            }
        }
        return lower..<upper
    }

    /// Start and end (before the newline) of the line that holds `index`.
    static func lineBounds(of index: Int, in chars: [Character]) -> (start: Int, end: Int) {
        var start = min(index, chars.count)
        while start > 0, chars[start - 1] != "\n" { start -= 1 }
        var end = min(index, chars.count)
        while end < chars.count, chars[end] != "\n" { end += 1 }
        return (start, end)
    }

    private static let markPattern = try! NSRegularExpression(pattern: #"^[ \t]*(#{1,6} |> |[-*+] \[[ xX]\] |[-*+] |\d+[.)] )?"#)

    /// Characters at the start of a Markdown line that are its mark (and its indent).
    static func markLength(_ line: String) -> Int {
        let ns = line as NSString
        guard let match = markPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return 0 }
        return ns.substring(with: match.range).count
    }

    private static let spanPatterns: [NSRegularExpression] = [
        #"\[\[[^\]\n]+\]\]"#,
        #"!?\[[^\]\n]*\]\([^)\n]*\)"#,
        #"`[^`\n]+`"#,
        #"\*\*[^*\n]+?\*\*"#,
        #"(?<!\*)\*[^*\n]+?\*(?!\*)"#,
        #"~~[^~\n]+?~~"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Character ranges of inline marks in one line.
    static func inlineSpans(in line: String) -> [Range<Int>] {
        let ns = line as NSString
        var spans: [Range<Int>] = []
        for pattern in spanPatterns {
            for match in pattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let lower = ns.substring(to: match.range.location).count
                let upper = lower + ns.substring(with: match.range).count
                spans.append(lower..<upper)
            }
        }
        return spans
    }

    /// The selection in the note as it is now: where it was when the note has not changed; otherwise the one
    /// place where the selected text is now. Nil when it cannot be found for sure.
    static func locate(_ target: RewriteTarget, in markdown: String) -> Range<Int>? {
        if markdown == target.markdown { return target.range }
        let selected = target.selected
        guard !selected.isEmpty else { return nil }
        var found: [Range<Int>] = []
        var searchStart = markdown.startIndex
        while let match = markdown.range(of: selected, range: searchStart..<markdown.endIndex) {
            let lower = markdown.distance(from: markdown.startIndex, to: match.lowerBound)
            found.append(lower..<(lower + selected.count))
            if found.count > 1 { return nil }
            searchStart = markdown.index(after: match.lowerBound)
        }
        return found.first
    }

    /// The note with the selection replaced by `text`, and where the new text is. An answer of several lines for
    /// all of one line's text takes the line's mark too (a paragraph that becomes a list).
    static func replacing(_ range: Range<Int>, with text: String, in markdown: String) -> (markdown: String, range: Range<Int>) {
        let chars = Array(markdown)
        let replacement = text.trimmingCharacters(in: .newlines)
        var lower = max(0, min(range.lowerBound, chars.count))
        let upper = max(lower, min(range.upperBound, chars.count))
        if replacement.contains("\n") {
            let line = lineBounds(of: lower, in: chars)
            let content = line.start + markLength(String(chars[line.start..<line.end]))
            if lower == content, upper == line.end, lower > line.start { lower = line.start }
        }
        let result = String(chars[..<lower]) + replacement + String(chars[upper...])
        return (result, lower..<(lower + replacement.count))
    }

    /// The note with `text` on new lines after the selection's last line, and where it is.
    static func insertingBelow(_ range: Range<Int>, text: String, in markdown: String) -> (markdown: String, range: Range<Int>) {
        let chars = Array(markdown)
        let insertion = text.trimmingCharacters(in: .newlines)
        let end = lineBounds(of: max(0, min(range.upperBound, chars.count) - 1), in: chars).end
        let result = String(chars[..<end]) + "\n" + insertion + String(chars[end...])
        return (result, (end + 1)..<(end + 1 + insertion.count))
    }
}

// MARK: - The model

enum AIRewriteError: LocalizedError {
    case tooLong(Int)
    case noModel

    var errorDescription: String? {
        switch self {
        case .tooLong(let limit): "The selection is too long for this model (up to \(limit.formatted()) characters). Select less or choose a cloud model."
        case .noModel: "No model is ready. Download or add one in Settings, under AI."
        }
    }
}

enum AIRewrite {
    /// Longest selection the model is given (the Apple model has a small window).
    static func limit(for model: SummaryModel) -> Int {
        if case .local(let local) = model { return local == .apple ? 3_000 : 10_000 }
        return 40_000
    }

    /// Text around the selection that goes along as context.
    static func contextLimit(for model: SummaryModel) -> Int {
        if case .local(let local) = model { return local == .apple ? 0 : 500 }
        return 1_000
    }

    /// Room for the answer: about as long as the passage, more when it is to grow.
    static func tokenLimit(for selection: String) -> Int {
        min(4_000, selection.count + 600)
    }

    static func prompt(instruction: String, selection: String, before: String = "", after: String = "") -> (system: String, user: String) {
        let language = SummaryLanguage.detect(in: selection)
        let system = """
        You are a writing assistant in a notes app. You rewrite the passage the user selected, following the instruction.
        - Answer with the rewritten passage only: no introduction, no explanation, no quotation marks around it, no code block.
        - The passage is Markdown. Keep its marks ("# " headings, "- " and "1. " lists, "- [ ] " and "- [x] " checkboxes, "> " quotes, **bold**, *italic*, links, [[links]], #tags) unless the instruction asks for another form.
        - Keep tables, images and "---" dividers exactly as they are.
        - Do not add facts that are not in the passage.
        - The passage is written in \(language.name). Unless the instruction asks for another language, write in \(language.name).
        """
        var user = "Instruction: \(instruction.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        if !before.isEmpty { user += "Text before the passage (context only, do not repeat it):\n\(before)\n\n" }
        if !after.isEmpty { user += "Text after the passage (context only, do not repeat it):\n\(after)\n\n" }
        user += "Passage:\n<<<\n\(selection)\n>>>"
        return (system, user)
    }

    /// The answer without what models add although asked not to: the `<<<`/`>>>` of the prompt, a code fence
    /// around everything, a "Here is …:" line on top.
    static func clean(_ answer: String, original: String) -> String {
        var lines = LocalLLM.withoutThinking(answer).components(separatedBy: "\n")
        func trimEnds() {
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        }
        trimEnds()
        if lines.first?.trimmingCharacters(in: .whitespaces) == "<<<" { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespaces) == ">>>" { lines.removeLast() }
        trimEnds()
        if let first = lines.first?.lowercased(), lines.count > 1, first.hasSuffix(":"),
           ["here is", "here's", "sure", "hier ist", "gerne", "certainly"].contains(where: first.hasPrefix) {
            lines.removeFirst()
            trimEnds()
        }
        if !original.hasPrefix("```"), lines.count >= 2, lines.first?.hasPrefix("```") == true, lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
            lines.removeFirst()
            lines.removeLast()
            trimEnds()
        }
        return lines.joined(separator: "\n")
    }

    /// The rewritten passage, with the model chosen in the sheet (by default the one of the settings).
    @MainActor
    static func run(instruction: String, target: RewriteTarget, model: SummaryModel, progress: @escaping (String) -> Void = { _ in }) async throws -> String {
        let selection = target.selected
        guard selection.count <= limit(for: model) else { throw AIRewriteError.tooLong(limit(for: model)) }
        let context = target.context(limit: contextLimit(for: model))
        let prompt = prompt(instruction: instruction, selection: selection, before: context.before, after: context.after)
        let raw: String
        switch model {
        case .local(let local):
            // A rewrite never starts a download of gigabytes on its own: the model is fetched in Settings.
            guard local.isInstalled else { throw AIRewriteError.noModel }
            let models = ModelManager.shared
            models.beginLLMUse()
            defer { models.endLLMUse() }
            progress("Loading model…")
            try await models.ensureLLM(local) { _ in }
            progress("Writing…")
            raw = try await LocalLLM.shared.generate(model: local, system: prompt.system, user: prompt.user, maxTokens: tokenLimit(for: selection))
        case .cloud(let provider, let id):
            let key = provider.apiKey
            if provider.requiresKey, key.isEmpty { throw SummaryError.missingAPIKey(provider.label) }
            progress("Writing…")
            let answer = try await ForegroundWork.retrying(waitsFirst: false) {
                try await CloudLLM.completion(provider: provider, apiKey: key, model: id, system: prompt.system, user: prompt.user)
            }
            if answer.truncated { throw SummaryError.provider("The model stopped before it was finished. Try a shorter selection or another model.") }
            raw = answer.text
        }
        let text = clean(raw, original: selection)
        guard !text.isEmpty else { throw SummaryError.emptyResponse }
        return text
    }
}

// MARK: - Changes

/// The words that changed between the selection and the rewrite, for the preview.
enum RewriteDiff {
    enum Kind: Equatable { case same, removed, added }

    struct Piece: Equatable {
        var kind: Kind
        var text: String
    }

    /// Words and the space between them, as separate tokens.
    static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentIsSpace: Bool?
        for character in text {
            let isSpace = character.isWhitespace
            if currentIsSpace != nil, isSpace != currentIsSpace {
                result.append(current)
                current = ""
            }
            current.append(character)
            currentIsSpace = isSpace
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Longer texts are shown as before and after instead (the comparison grows with the product of both lengths).
    static let maxTokens = 2_500

    /// The changes word by word; nil when the texts are too long to compare.
    static func pieces(from old: String, to new: String) -> [Piece]? {
        let a = tokens(old), b = tokens(new)
        guard a.count <= maxTokens, b.count <= maxTokens else { return nil }
        // Longest common subsequence, from the end.
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pieces: [Piece] = []
        func add(_ kind: Kind, _ text: String) {
            if let last = pieces.last, last.kind == kind { pieces[pieces.count - 1].text += text } else { pieces.append(Piece(kind: kind, text: text)) }
        }
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                add(.same, a[i]); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                add(.removed, a[i]); i += 1
            } else {
                add(.added, b[j]); j += 1
            }
        }
        while i < a.count { add(.removed, a[i]); i += 1 }
        while j < b.count { add(.added, b[j]); j += 1 }
        return pieces
    }
}
