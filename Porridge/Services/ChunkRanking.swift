import Foundation
import NaturalLanguage

/// A passage of a note or a meeting transcript the chat can quote. Stored in the index (`NoteIndex`)
/// with its word statistics and, once computed, its sentence vector.
struct ChatChunk: Codable {
    let noteID: UUID
    let title: String
    let date: Date
    let text: String
    let frequencies: [String: Int]
    let prefixFrequencies: [String: Int]
    let length: Int
    /// Normalized sentence vector (`TextEmbedder`); nil until it was computed.
    var embedding: [Float]?

    enum CodingKeys: String, CodingKey {
        case noteID, title, date, text, frequencies, prefixFrequencies, length, embeddingData
    }

    init(noteID: UUID, title: String, date: Date, text: String, frequencies: [String: Int], prefixFrequencies: [String: Int], length: Int, embedding: [Float]? = nil) {
        self.noteID = noteID
        self.title = title
        self.date = date
        self.text = text
        self.frequencies = frequencies
        self.prefixFrequencies = prefixFrequencies
        self.length = length
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
    static func search(_ query: String, in chunks: [ChatChunk], queryVector: [Float]? = nil, budget: Int = 6500) -> [ChatChunk] {
        let words = Array(Set(tokens(query)))
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

