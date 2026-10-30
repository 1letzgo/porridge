import Foundation

enum Paragraphs {
    /// Splits running text into paragraphs of at most `maxSentences` sentences (and about `maxLength` characters).
    /// Returns the paragraphs and how many sentences the last one has.
    static func split(_ text: String, maxSentences: Int = 2, maxLength: Int = 220) -> (paragraphs: [String], lastSentenceCount: Int) {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sub, _, _, _ in
            if let sub = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !sub.isEmpty { sentences.append(sub) }
        }
        var paragraphs: [String] = []
        var count = 0
        for sentence in sentences {
            if let last = paragraphs.last, count < maxSentences, last.count + sentence.count < maxLength {
                paragraphs[paragraphs.count - 1] = last + " " + sentence
                count += 1
            } else {
                paragraphs.append(sentence)
                count = 1
            }
        }
        return (paragraphs, count)
    }

    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sub, _, _, _ in
            if let sub = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !sub.isEmpty { result.append(sub) }
        }
        return result
    }

    /// Groups sentences into paragraphs, keeping a flag per sentence (used to dim unconfirmed text).
    static func group(_ sentences: [(text: String, flag: Bool)], maxSentences: Int = 2, maxLength: Int = 220) -> [[(text: String, flag: Bool)]] {
        var paragraphs: [[(text: String, flag: Bool)]] = []
        for sentence in sentences {
            if var last = paragraphs.last, last.count < maxSentences,
               last.reduce(0, { $0 + $1.text.count }) + sentence.text.count < maxLength {
                last.append(sentence)
                paragraphs[paragraphs.count - 1] = last
            } else {
                paragraphs.append([sentence])
            }
        }
        return paragraphs
    }

    /// Plain-text version for storing: paragraphs separated by a blank line.
    static func format(_ text: String) -> String {
        split(text).paragraphs.joined(separator: "\n\n")
    }
}
