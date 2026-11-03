import Foundation
import NaturalLanguage

/// A passage of a note or a meeting transcript with its word statistics, stored in the index (`NoteIndex`).
struct NoteChunk: Codable {
    let noteID: UUID
    let text: String
    let frequencies: [String: Int]
    let prefixFrequencies: [String: Int]
}

/// Cuts notes and meetings into passages, and tells whether a word is in one.
enum NoteChunks {
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
    static func frequency(_ word: String, _ chunk: NoteChunk) -> Double {
        let exact = Double(chunk.frequencies[word] ?? 0)
        guard let key = prefix(word) else { return exact }
        return exact + 0.5 * Double(chunk.prefixFrequencies[key] ?? 0)
    }
}

extension NoteChunks {
    private static func chunk(_ note: Note, text: String) -> NoteChunk {
        let words = tokens(note.displayTitle + " " + note.tags.joined(separator: " ") + " " + text)
        var frequencies: [String: Int] = [:]
        var prefixes: [String: Int] = [:]
        for word in words {
            frequencies[word, default: 0] += 1
            if let key = prefix(word) { prefixes[key, default: 0] += 1 }
        }
        return NoteChunk(noteID: note.id, text: text, frequencies: frequencies, prefixFrequencies: prefixes)
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

    static func chunks(from notes: [Note]) -> [NoteChunk] {
        var result: [NoteChunk] = []
        for note in notes where !note.isDeleted {
            // A saved link is found by its address and site, even when its page could not be read.
            if let url = note.url, !url.isEmpty {
                result.append(chunk(note, text: "Saved link" + (note.domain.map { " (\($0))" } ?? "") + ": " + url))
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
