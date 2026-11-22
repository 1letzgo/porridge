import Foundation

/// Fuzzy matching for the command bar: the typed letters appear in the text in order, not necessarily next to each
/// other ("rcm" finds "Record Meeting"). Case and accents do not matter ("uber" finds "Über"). Matches at the start of
/// a word, in a run and near the start score higher. Several words in the query must each match.
enum FuzzyMatch {
    /// A score (higher is better), or nil when the text does not match.
    static func score(_ query: String, in text: String) -> Int? {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return 0 }
        let target = Array(fold(text))
        guard !target.isEmpty else { return nil }
        var total = 0
        for word in words {
            guard let part = scoreWord(Array(word), in: target) else { return nil }
            total += part
        }
        // Shorter texts win among equal matches: "Inbox" before "Inbox of last year".
        return total * 4 - min(target.count, 120) / 8
    }

    /// The best score of the query in any of the texts (a title, a bowl's name and its other names).
    static func score(_ query: String, in texts: [String]) -> Int? {
        texts.compactMap { score(query, in: $0) }.max()
    }

    /// Items that match, best first; ties keep their order.
    static func rank<T>(_ items: [T], query: String, text: (T) -> String) -> [T] {
        items.enumerated()
            .compactMap { index, item in score(query, in: text(item)).map { (index, item, $0) } }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            .map(\.1)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// One word of the query: a whole substring is best (at a word start better still), otherwise the letters in order.
    private static func scoreWord(_ word: [Character], in target: [Character]) -> Int? {
        // A substring: found as it was typed.
        if let start = substringStart(word, in: target) {
            let atWord = start == 0 || !target[start - 1].isLetterOrDigit
            let end = start + word.count
            let wholeWord = atWord && (end == target.count || !target[end].isLetterOrDigit)
            return 100 + word.count * 10 + (atWord ? 40 : 0) + (wholeWord ? 25 : 0) + (start == 0 ? 10 : 0) - min(start, 30)
        }
        // The letters in order, preferring word starts; when that runs out of text, simply each as early as possible.
        return lettersInOrder(word, in: target, preferWordStarts: true) ?? lettersInOrder(word, in: target, preferWordStarts: false)
    }

    private static func lettersInOrder(_ word: [Character], in target: [Character], preferWordStarts: Bool) -> Int? {
        var score = 0
        var position = 0
        var previous: Int?
        for char in word {
            guard let found = nextMatch(char, in: target, from: position, preferWordStart: preferWordStarts) else { return nil }
            let atWord = found == 0 || !target[found - 1].isLetterOrDigit
            if let previous, found == previous + 1 {
                score += 8
            } else if atWord {
                score += 6
            } else {
                score += 1
                // Far jumps inside words make a poor match.
                score -= min(found - position, 10) / 3
            }
            previous = found
            position = found + 1
        }
        return max(score, 1)
    }

    private static func substringStart(_ word: [Character], in target: [Character]) -> Int? {
        guard word.count <= target.count else { return nil }
        var best: Int?
        for start in 0...(target.count - word.count) where Array(target[start..<(start + word.count)]) == word {
            let atWord = start == 0 || !target[start - 1].isLetterOrDigit
            if atWord { return start }
            if best == nil { best = start }
        }
        return best
    }

    /// The next place of the letter from `position`: the next one continuing a run, else the first word start that
    /// holds it (when preferred), else the first place at all.
    private static func nextMatch(_ char: Character, in target: [Character], from position: Int, preferWordStart: Bool) -> Int? {
        guard position < target.count else { return nil }
        if target[position] == char || !preferWordStart {
            return target[position...].firstIndex(of: char)
        }
        var first: Int?
        for index in position..<target.count where target[index] == char {
            if first == nil { first = index }
            let atWord = index == 0 || !target[index - 1].isLetterOrDigit
            if atWord { return index }
        }
        return first
    }
}

private extension Character {
    var isLetterOrDigit: Bool { isLetter || isNumber }
}
