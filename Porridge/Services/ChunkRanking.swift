import Foundation
import NaturalLanguage

/// A passage of a note or a meeting transcript the chat can quote. Stored in the index (`NoteIndex`)
/// with its word statistics and, once computed, its sentence vector.
struct ChatChunk: Codable {
    /// Where in its entry a passage comes from.
    enum Part: String, Codable {
        case title, link, files, todo, summary, text, page, transcript

        /// The passages that hold content; title, link, files and to-do state are in the entry's header already.
        var fillsContext: Bool { [.summary, .text, .page, .transcript].contains(self) }
    }

    let noteID: UUID
    let title: String
    let date: Date
    let text: String
    let frequencies: [String: Int]
    let prefixFrequencies: [String: Int]
    let length: Int
    var part: Part = .text
    /// Normalized sentence vector (`TextEmbedder`); nil until it was computed.
    var embedding: [Float]?

    enum CodingKeys: String, CodingKey {
        case noteID, title, date, text, frequencies, prefixFrequencies, length, embeddingData, part
    }

    init(noteID: UUID, title: String, date: Date, text: String, frequencies: [String: Int], prefixFrequencies: [String: Int], length: Int, part: Part = .text, embedding: [Float]? = nil) {
        self.noteID = noteID
        self.title = title
        self.date = date
        self.text = text
        self.frequencies = frequencies
        self.prefixFrequencies = prefixFrequencies
        self.length = length
        self.part = part
        self.embedding = embedding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        noteID = try container.decode(UUID.self, forKey: .noteID)
        title = try container.decode(String.self, forKey: .title)
        date = try container.decode(Date.self, forKey: .date)
        text = try container.decode(String.self, forKey: .text)
        frequencies = try container.decode([String: Int].self, forKey: .frequencies)
        prefixFrequencies = try container.decode([String: Int].self, forKey: .prefixFrequencies)
        length = try container.decode(Int.self, forKey: .length)
        part = (try? container.decodeIfPresent(Part.self, forKey: .part)) ?? .text
        // The vector as raw Float32 bytes: a fraction of the size of a list of numbers.
        embedding = try container.decodeIfPresent(Data.self, forKey: .embeddingData).map { data in
            data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(noteID, forKey: .noteID)
        try container.encode(title, forKey: .title)
        try container.encode(date, forKey: .date)
        try container.encode(text, forKey: .text)
        try container.encode(frequencies, forKey: .frequencies)
        try container.encode(prefixFrequencies, forKey: .prefixFrequencies)
        try container.encode(length, forKey: .length)
        try container.encode(part, forKey: .part)
        if let embedding {
            try container.encode(embedding.withUnsafeBufferPointer { Data(buffer: $0) }, forKey: .embeddingData)
        }
    }
}

/// Cuts notes and meetings into passages and ranks them for a question: by words (BM25) and, when the
/// passages have vectors, by meaning.
enum ChatRetrieval {
    static let chunkSize = 700

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

    static func prefix(_ token: String) -> String? {
        token.count >= 5 ? String(token.prefix(5)) : nil
    }

    /// How often `word` is in a chunk: exact, or half for another word with the same first five letters (word forms).
    static func frequency(_ word: String, _ chunk: ChatChunk) -> Double {
        let exact = Double(chunk.frequencies[word] ?? 0)
        guard let key = prefix(word) else { return exact }
        return exact + 0.5 * Double(chunk.prefixFrequencies[key] ?? 0)
    }

    /// The passages that fit `query` best, within `budget` characters. With `queryVector`, the meaning
    /// counts too. The cosines of this embedding are not absolute (unrelated passages score 0.8), so a
    /// passage counts by meaning only when it stands out from all others for this question (z-score),
    /// and among the passages with the words, the meaning decides the order.
    /// At most this many passages of one note: a long note must not take all the places.
    static let passagesPerNote = 3

    static func search(_ query: String, in chunks: [ChatChunk], queryVector: [Float]? = nil, budget: Int = 6500) -> [ChatChunk] {
        search(words: queryWords(query), in: chunks, queryVector: queryVector, budget: budget)
    }

    /// `search` with the words already read from the question (`ChatQuery.words`).
    static func search(words: [String], in chunks: [ChatChunk], queryVector: [Float]? = nil, budget: Int = 6500) -> [ChatChunk] {
        let words = Array(Set(words))
        guard !words.isEmpty, !chunks.isEmpty else { return [] }

        let average = Double(chunks.reduce(0) { $0 + $1.length }) / Double(chunks.count)
        let count = Double(chunks.count)

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

        if let queryVector {
            let cosines: [Double?] = chunks.map { chunk in
                chunk.embedding.map { Double(TextEmbedder.similarity(queryVector, $0)) }
            }
            let known = cosines.compactMap { $0 }
            if known.count >= 3 {
                let mean = known.reduce(0, +) / Double(known.count)
                let deviation = max(sqrt(known.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(known.count)), 0.001)
                let best = scores.max() ?? 0
                for index in chunks.indices {
                    let lexical = best > 0 ? scores[index] / best : 0
                    guard let cosine = cosines[index] else {
                        scores[index] = lexical * 0.7
                        continue
                    }
                    let z = (cosine - mean) / deviation
                    // 0 at the average, 1 at three deviations above it.
                    let standing = min(1, max(0, z / 3))
                    if lexical > 0 {
                        scores[index] = 0.7 * lexical + 0.3 * standing
                    } else if z >= 2.5 {
                        scores[index] = 0.3 * standing
                    } else {
                        scores[index] = 0
                    }
                }
            }
        }

        let ranked = chunks.indices.filter { scores[$0] > 0 }.sorted { scores[$0] > scores[$1] }
        var picked: [ChatChunk] = []
        var perNote: [UUID: Int] = [:]
        var used = 0
        for index in ranked {
            let chunk = chunks[index]
            if perNote[chunk.noteID, default: 0] >= passagesPerNote { continue }
            if used + chunk.text.count > budget, !picked.isEmpty { break }
            picked.append(chunk)
            perNote[chunk.noteID, default: 0] += 1
            used += chunk.text.count
            if picked.count >= 10 { break }
        }
        return picked
    }

    /// The passages a chat question is answered from. A question about a time ("der letzten Tage", "this week")
    /// looks at the notes of that time first; when nothing there fits, at all of them. With no word to search for
    /// ("Was war diese Woche?") the newest notes (of that time) are the context.
    static func select(
        _ question: String, in chunks: [ChatChunk], queryVector: [Float]? = nil,
        now: Date = Date(), calendar: Calendar = .current, budget: Int = 6500, recentBudget: Int = 4500
    ) -> [ChatChunk] {
        var window: [ChatChunk] = []
        if let start = since(in: question, now: now, calendar: calendar) {
            window = chunks.filter { $0.date >= start }
            let found = search(question, in: window, queryVector: queryVector, budget: budget)
            if !found.isEmpty { return found }
        }
        let found = search(question, in: chunks, queryVector: queryVector, budget: budget)
        if !found.isEmpty { return found }
        return recent(from: window.isEmpty ? chunks : window, budget: recentBudget)
    }

    // MARK: - The question

    /// The words of a question worth searching for: without the words every text has ("die", "the"), the phrasing
    /// of a request ("stelle mir … vor", "show me") and the words of time ("letzten Tage"), which `since` reads.
    /// Only questions are cut this way; the passages keep all their words.
    static func queryWords(_ question: String) -> [String] {
        tokens(question).filter { !stopWords.contains($0) }
    }

    /// German and English words that say nothing about what is searched for.
    static let stopWords: Set<String> = [
        // German: articles, pronouns, prepositions, conjunctions, auxiliaries
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines",
        "ich", "du", "er", "sie", "es", "wir", "ihr", "mir", "mich", "dir", "dich", "uns", "euch", "ihm", "ihn", "ihnen",
        "mein", "meine", "meinen", "meinem", "meiner", "dein", "deine", "unser", "unsere", "unseren", "unserem", "sein", "seine",
        "und", "oder", "aber", "doch", "denn", "dass", "ob", "wenn", "als", "wie", "so", "auch", "noch", "nur", "schon",
        "nicht", "kein", "keine", "keinen", "sehr", "mal", "bitte", "gerne", "gern", "etwa", "ja", "nein",
        "in", "im", "an", "am", "auf", "aus", "bei", "beim", "mit", "nach", "von", "vom", "vor", "zu", "zum", "zur",
        "für", "über", "unter", "um", "bis", "seit", "durch", "gegen", "ohne", "zwischen", "ab",
        "ist", "sind", "war", "waren", "bin", "bist", "seid", "wird", "werden", "wurde", "wurden", "hat", "habe", "haben",
        "hatte", "hatten", "hast", "kann", "können", "konnte", "soll", "sollen", "muss", "müssen", "will", "wollen", "gibt", "gab",
        "was", "wer", "wen", "wem", "wo", "wann", "warum", "wieso", "weshalb", "welche", "welcher", "welches", "welchen", "woran", "worüber",
        "hier", "da", "dort", "dann", "jetzt", "alle", "alles", "allen", "etwas", "viel", "viele", "mehr", "einige", "paar",
        // German: the phrasing of a request
        "stelle", "stell", "stellen", "zeig", "zeige", "zeigen", "nenne", "nenn", "nennen", "gib", "geben", "sag", "sage", "sagen",
        "erzähl", "erzähle", "erzählen", "fasse", "fass", "zusammen", "zusammenfassen", "liste", "auflisten", "finde", "finden",
        "suche", "such", "erkläre", "erklär", "beschreibe", "vorstellen", "möchte", "würde", "wüsste", "weißt", "kannst", "könntest",
        "thema", "themen", "bezug", "gespeichert", "notiert", "gemerkt", "abgelegt", "steht", "stehen", "liegt", "liegen", "drin",
        "beschäftigt",
        "highlights", "überblick", "übersicht", "zusammenfassung", "neuigkeiten", "neues", "infos", "informationen",
        // German: time (read by `since`)
        "heute", "gestern", "vorgestern", "letzte", "letzten", "letzter", "letztes", "vergangene", "vergangenen", "vergangener",
        "diese", "dieser", "diesen", "diesem", "dieses", "tage", "tagen", "woche", "wochen", "monat", "monate", "monaten",
        "zeit", "kürzlich", "neulich", "zuletzt", "neueste", "neuesten", "aktuell", "aktuelle", "aktuellen",
        // English
        "the", "a", "an", "and", "or", "but", "of", "to", "in", "on", "at", "for", "from", "with", "by", "about", "into", "over",
        "is", "are", "was", "were", "be", "been", "do", "does", "did", "have", "has", "had", "can", "could", "would", "should", "will",
        "i", "me", "my", "we", "us", "our", "you", "your", "he", "she", "it", "they", "them", "their", "this", "that", "these", "those",
        "what", "which", "who", "whom", "when", "where", "why", "how", "there", "here", "any", "all", "some", "please", "tell",
        "show", "give", "list", "find", "summarize", "summary", "overview", "explain", "describe", "know",
        "topic", "topics", "saved", "stored", "kept", "noted", "regarding", "related",
        "today", "yesterday", "last", "past", "few", "days", "day", "week", "weeks", "month", "months", "recent", "recently", "lately", "latest", "new",
    ]

    private static let dayWords: Set<String> = ["tag", "tage", "tagen", "day", "days"]
    private static let weekWords: Set<String> = ["woche", "wochen", "week", "weeks"]
    private static let monthWords: Set<String> = ["monat", "monate", "monaten", "month", "months"]
    private static let numberWords: [String: Int] = [
        "ein": 1, "einen": 1, "einem": 1, "eine": 1, "zwei": 2, "drei": 3, "vier": 4, "fünf": 5, "sechs": 6, "sieben": 7, "acht": 8, "neun": 9, "zehn": 10,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]

    /// Since when a question asks ("heute", "der letzten Tage", "last 3 days", "this week"), or nil when it names
    /// no time. Weeks start on Monday.
    static func since(in question: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let words = question.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let text = " " + words.joined(separator: " ") + " "
        func has(_ phrases: [String]) -> Bool { phrases.contains { text.contains(" \($0) ") } }
        let today = calendar.startOfDay(for: now)
        func daysBack(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: today) ?? today }
        let weekday = calendar.component(.weekday, from: today)  // 1 is Sunday
        let thisWeek = daysBack((weekday + 5) % 7)
        let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today

        // "der letzten 3 Tage", "last two weeks"
        for (index, word) in words.enumerated() where index + 1 < words.count {
            guard let count = Int(word) ?? numberWords[word], count > 0, count < 1000 else { continue }
            let unit = words[index + 1]
            if dayWords.contains(unit) { return daysBack(count) }
            if weekWords.contains(unit) { return daysBack(7 * count) }
            if monthWords.contains(unit) { return calendar.date(byAdding: .month, value: -count, to: today) ?? today }
        }
        if has(["heute", "today"]) { return today }
        if has(["vorgestern"]) { return daysBack(2) }
        if has(["gestern", "yesterday"]) { return daysBack(1) }
        if has(["diese woche", "dieser woche", "diesen woche", "this week"]) { return thisWeek }
        if has(["letzte woche", "letzten woche", "letzter woche", "vergangene woche", "vergangenen woche", "last week", "past week"]) {
            return calendar.date(byAdding: .day, value: -7, to: thisWeek) ?? thisWeek
        }
        if has(["diesen monat", "diesem monat", "dieser monat", "this month"]) { return thisMonth }
        if has(["letzten monat", "letzter monat", "letzte monat", "vergangenen monat", "last month", "past month"]) {
            return calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth
        }
        if has([
            "letzten tage", "letzte tage", "letzten tagen", "vergangenen tage", "vergangenen tagen", "paar tage", "paar tagen",
            "letzter zeit", "letzten zeit", "kürzlich", "neulich", "zuletzt", "neueste", "neuesten",
            "last days", "last few days", "past days", "past few days", "recent", "recently", "lately", "latest",
        ]) { return daysBack(7) }
        return nil
    }

    /// With nothing matching ("what happened this week?"), the newest summaries and notes are the context.
    static func recent(from chunks: [ChatChunk], budget: Int = 4500) -> [ChatChunk] {
        var picked: [ChatChunk] = []
        var used = 0
        // A to-do's passage is dated by its due day: one due next month is not the newest entry.
        let now = Date()
        for chunk in chunks.sorted(by: { min($0.date, now) > min($1.date, now) }) {
            if used + chunk.text.count > budget, !picked.isEmpty { break }
            picked.append(chunk)
            used += chunk.text.count
            if picked.count >= 8 { break }
        }
        return picked
    }
}

