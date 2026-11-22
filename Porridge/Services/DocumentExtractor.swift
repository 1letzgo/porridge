import Foundation

/// Reads what a document is out of its text, on the device and without a model: its kind from words like
/// "Rechnung" or "Invoice", the date on it, the sender from its letterhead and the total. German and English.
/// A first guess right after the text was read; the summary's model (`DocumentLine`) and the user correct it.
enum DocumentExtractor {
    /// Only the start of a long document is looked at: the letterhead, date and total of a bill are there, the
    /// pages after are small print.
    static let readLength = 6_000

    /// `senderHint` and `dayHint` come from around the document (the mail it was attached to): taken only when the
    /// document itself names no sender or date, the sender only for a paper (a PDF or office file, or one whose kind
    /// was found), so a holiday photo sent by a friend does not become a document of theirs.
    static func extract(from text: String, name: String = "", senderHint: String? = nil, dayHint: String? = nil, now: Date = Date()) -> DocumentInfo {
        let head = String(text.prefix(readLength))
        let kind = kind(in: head, name: name)
        var info = DocumentInfo(kind: kind)
        info.day = day(in: head, now: now) ?? dayHint
        let isPaper = kind != nil || Attachment.documentExtensions.contains((name as NSString).pathExtension.lowercased())
        info.correspondent = correspondent(in: head) ?? (isPaper ? senderHint.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) } : nil)
        let found = amount(in: head)
        if let found, found.labelled || (kind?.hasAmount ?? false) { info.amount = found.value }
        return info
    }

    // MARK: Kind

    /// Words that name a kind, with their weight: words that only that kind uses weigh more.
    private static let kindWords: [(DocumentKind, [(String, Int)])] = [
        (.invoice, [("rechnungsnummer", 4), ("rechnungsbetrag", 4), ("rechnungsdatum", 4), ("invoice", 4), ("rechnung", 3),
                    ("facture", 3), ("factura", 3), ("fattura", 3), ("zahlbar bis", 1), ("due date", 1), ("bill to", 2)]),
        (.receipt, [("kassenbon", 5), ("kassenbeleg", 5), ("quittung", 5), ("receipt", 5), ("bon-nr", 4), ("bonnr", 4),
                    ("vielen dank für ihren einkauf", 4), ("thank you for your purchase", 4), ("kartenzahlung", 2), ("gegeben", 2),
                    ("rückgeld", 3), ("change due", 3)]),
        (.contract, [("vertragsnummer", 3), ("vertragspartner", 4), ("vertrag", 3), ("vereinbarung", 2), ("contract", 4),
                     ("agreement", 3), ("laufzeit", 1), ("unterschrift", 1), ("signature", 1)]),
        (.statement, [("kontoauszug", 6), ("depotauszug", 6), ("account statement", 6), ("statement of account", 6),
                      ("alter kontostand", 4), ("neuer kontostand", 4), ("opening balance", 4), ("closing balance", 4)]),
        (.payslip, [("gehaltsabrechnung", 7), ("lohnabrechnung", 7), ("entgeltabrechnung", 7), ("verdienstabrechnung", 7),
                    ("payslip", 7), ("pay slip", 7), ("gross pay", 3), ("net pay", 3), ("auszahlungsbetrag", 3)]),
        (.notice, [("bescheid", 5), ("finanzamt", 4), ("aktenzeichen", 3), ("behörde", 2), ("rechtsbehelfsbelehrung", 4),
                   ("notice of assessment", 6), ("steuernummer", 2)]),
        (.certificate, [("bescheinigung", 5), ("zeugnis", 5), ("zertifikat", 5), ("certificate", 5), ("urkunde", 5),
                        ("hiermit bestätigen wir", 3), ("we hereby confirm", 3)]),
        (.offer, [("kostenvoranschlag", 6), ("angebotsnummer", 6), ("angebot", 4), ("quotation", 5), ("quote", 3),
                  ("gültig bis", 1), ("valid until", 1)]),
        (.insurance, [("versicherungsschein", 6), ("versicherungsnummer", 4), ("versicherung", 2), ("insurance policy", 6),
                      ("policy number", 4), ("beitrag", 1), ("premium", 1)]),
        (.letter, [("sehr geehrte", 2), ("mit freundlichen grüßen", 2), ("dear ", 2), ("kind regards", 2), ("sincerely", 2),
                   ("yours faithfully", 2)]),
    ]

    /// The kind with the most weight; the file's name counts three times. Nil when no word fits.
    static func kind(in text: String, name: String = "") -> DocumentKind? {
        let body = text.lowercased()
        let title = name.lowercased()
        var best: (kind: DocumentKind, score: Int)?
        for (kind, words) in kindWords {
            var score = 0
            for (word, weight) in words {
                if body.contains(word) { score += weight }
                if !title.isEmpty, title.contains(word) { score += weight * 3 }
            }
            // A letter is what is left: any other kind with words wins over the greeting.
            if kind == .letter { score = min(score, 3) }
            if score > 0, score > (best?.score ?? 0) { best = (kind, score) }
        }
        return best?.kind
    }

    // MARK: Date

    private static let monthNames: [String: Int] = [
        "januar": 1, "jänner": 1, "january": 1, "jan": 1,
        "februar": 2, "february": 2, "feb": 2,
        "märz": 3, "maerz": 3, "march": 3, "mär": 3, "mrz": 3, "mar": 3,
        "april": 4, "apr": 4,
        "mai": 5, "may": 5,
        "juni": 6, "june": 6, "jun": 6,
        "juli": 7, "july": 7, "jul": 7,
        "august": 8, "aug": 8,
        "september": 9, "sept": 9, "sep": 9,
        "oktober": 10, "october": 10, "okt": 10, "oct": 10,
        "november": 11, "nov": 11,
        "dezember": 12, "december": 12, "dez": 12, "dec": 12,
    ]

    private static let monthPattern = monthNames.keys.sorted { $0.count > $1.count }.joined(separator: "|")

    private static let numericDate = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,2})\.\s?(\d{1,2})\.\s?(\d{4}|\d{2})(?!\d)"#)
    private static let isoDate = try! NSRegularExpression(pattern: #"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)"#)
    private static let slashDate = try! NSRegularExpression(pattern: #"(?<!\d)(\d{1,2})/(\d{1,2})/(\d{4})(?!\d)"#)
    private static let dayMonthYear = try! NSRegularExpression(
        pattern: #"(?<!\d)(\d{1,2})\.?\s+("# + monthPattern + #")\.?\s+(\d{4})(?!\d)"#, options: .caseInsensitive
    )
    private static let monthDayYear = try! NSRegularExpression(
        pattern: #"(?<![\p{L}])("# + monthPattern + #")\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})(?!\d)"#, options: .caseInsensitive
    )

    /// Words before the date of the document itself; other dates (due, birth, period) are only taken without one.
    private static let dateLabels = ["rechnungsdatum", "belegdatum", "datum", "invoice date", "date of issue", "issued", "date", "ausgestellt", "vom"]
    private static let otherDateLabels = ["fällig", "zahlbar", "due", "geburt", "birth", "zeitraum", "period", "lieferdatum", "gültig", "valid", "bis "]

    /// All dates in a line, in order, as day keys ("2026-03-02").
    static func dates(in line: String) -> [String] {
        let range = NSRange(line.startIndex..., in: line)
        var found: [(Int, String)] = []
        func int(_ match: NSTextCheckingResult, _ group: Int) -> Int? {
            Range(match.range(at: group), in: line).flatMap { Int(line[$0]) }
        }
        func text(_ match: NSTextCheckingResult, _ group: Int) -> String {
            Range(match.range(at: group), in: line).map { String(line[$0]).lowercased() } ?? ""
        }
        func add(_ match: NSTextCheckingResult, year: Int?, month: Int?, day: Int?) {
            guard let year, let month, let day, let key = DocumentInfo.dayKey(year: year, month: month, day: day) else { return }
            found.append((match.range.location, key))
        }
        for match in numericDate.matches(in: line, range: range) {
            let year = int(match, 3).map { $0 < 100 ? $0 + 2000 : $0 }
            add(match, year: year, month: int(match, 2), day: int(match, 1))
        }
        for match in isoDate.matches(in: line, range: range) {
            add(match, year: int(match, 1), month: int(match, 2), day: int(match, 3))
        }
        for match in slashDate.matches(in: line, range: range) {
            guard let first = int(match, 1), let second = int(match, 2) else { continue }
            // 03/14/2026 is American, 14/03/2026 European; ambiguous ones are read the American way.
            add(match, year: int(match, 3), month: first > 12 ? second : first, day: first > 12 ? first : second)
        }
        for match in dayMonthYear.matches(in: line, range: range) {
            add(match, year: int(match, 3), month: monthNames[text(match, 2)], day: int(match, 1))
        }
        for match in monthDayYear.matches(in: line, range: range) {
            add(match, year: int(match, 3), month: monthNames[text(match, 1)], day: int(match, 2))
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The date of the document: one named as such ("Datum", "Invoice date"), otherwise the first date that is not
    /// a due date, a birthday or the end of a period, otherwise the first date at all. Dates far ahead are skipped.
    static func day(in text: String, now: Date = Date()) -> String? {
        let latest = DocumentInfo.dayKey(now.addingTimeInterval(60 * 86_400))
        var labelled: String?
        var plain: String?
        var any: String?
        for line in text.components(separatedBy: .newlines) {
            let dates = dates(in: line).filter { $0 <= latest && $0 >= "1950-01-01" }
            guard let first = dates.first else { continue }
            let lower = line.lowercased()
            let isOther = otherDateLabels.contains { lower.contains($0) }
            if labelled == nil, !isOther, dateLabels.contains(where: { lower.contains($0) }) { labelled = first }
            if plain == nil, !isOther { plain = first }
            if any == nil { any = first }
        }
        return labelled ?? plain ?? any
    }

    // MARK: Amount

    /// A number with cents: "1.234,56", "1,234.56", "1234,56", "12.50", maybe negative. Not a date ("12.03.2026").
    private static let number = try! NSRegularExpression(
        pattern: #"(?<![\d.,])-?\d{1,3}(?:[.,']\d{3})*[.,]\d{2}(?!\d|[.,]\d)|(?<![\d.,])-?\d+[.,]\d{2}(?!\d|[.,]\d)"#
    )

    private static let currencyCode = try! NSRegularExpression(pattern: #"(?<![\p{L}])(eur|euro|usd|gbp|chf)(?![\p{L}])"#, options: .caseInsensitive)

    /// Labels of a total, with weight; net amounts, taxes and subtotals count against a line.
    private static let amountLabels: [(String, Int)] = [
        ("gesamtbetrag", 4), ("rechnungsbetrag", 4), ("zu zahlen", 4), ("zahlbetrag", 4), ("endbetrag", 4), ("auszahlungsbetrag", 4),
        ("amount due", 4), ("total due", 4), ("grand total", 4), ("balance due", 4),
        ("gesamtsumme", 3), ("gesamt", 3), ("summe", 2), ("total", 3), ("brutto", 2), ("betrag", 1), ("amount", 1),
        ("netto", -3), ("net ", -3), ("subtotal", -3), ("zwischensumme", -3), ("mwst", -3), ("ust", -2), ("vat", -3), ("tax", -2),
        ("steuer", -2), ("rabatt", -2), ("discount", -2), ("gegeben", -3), ("rückgeld", -4), ("change", -2),
    ]

    /// The currency named in a line: a sign or a code.
    static func currency(in line: String) -> String? {
        if line.contains("€") { return "EUR" }
        if line.contains("£") { return "GBP" }
        if line.contains("$") { return "USD" }
        guard let match = currencyCode.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        let code = line[range].uppercased()
        return code == "EURO" ? "EUR" : code
    }

    /// A label counts at the start of a word: "ust" is VAT, "August" is not.
    private static func hasLabel(_ lower: String, _ word: String) -> Bool {
        var start = lower.startIndex
        while let range = lower.range(of: word, range: start..<lower.endIndex) {
            if range.lowerBound == lower.startIndex || !lower[lower.index(before: range.lowerBound)].isLetter { return true }
            start = range.upperBound
        }
        return false
    }

    /// The total of the document as "119.00 EUR". `labelled` says whether a line named it a total.
    static func amount(in text: String) -> (value: String, labelled: Bool)? {
        var best: (value: Decimal, currency: String?, score: Int)?
        var firstCurrency: String?
        for line in text.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            let currency = currency(in: line)
            if firstCurrency == nil { firstCurrency = currency }
            let range = NSRange(line.startIndex..., in: line)
            let values = number.matches(in: line, range: range).compactMap { match in
                Range(match.range, in: line).flatMap { parseNumber(String(line[$0])) }
            }
            // The last number of a line is its amount: "Summe 2 Artikel 19,99".
            guard let value = values.last, value > 0 else { continue }
            let label = amountLabels.reduce(0) { hasLabel(lower, $1.0) ? $0 + $1.1 : $0 }
            // A line without a label and without a currency is a number in a table, not an amount.
            guard label > 0 || currency != nil else { continue }
            let score = label * 10 + (currency != nil ? 1 : 0)
            if let current = best, score < current.score || (score == current.score && value <= current.value) { continue }
            best = (value, currency, score)
        }
        guard let best else { return nil }
        let currency = best.currency ?? firstCurrency
        let value = format(best.value)
        return (currency.map { value + " " + $0 } ?? value, best.score >= 10)
    }

    /// "1234.5" → "1234.50": always two places, a point.
    static func format(_ value: Decimal) -> String {
        var rounded = Decimal()
        var copy = value
        NSDecimalRound(&rounded, &copy, 2, .plain)
        let plain = NSDecimalNumber(decimal: rounded).stringValue
        guard let point = plain.firstIndex(of: ".") else { return plain + ".00" }
        let places = plain.distance(from: point, to: plain.endIndex) - 1
        return places >= 2 ? plain : plain + String(repeating: "0", count: 2 - places)
    }

    /// "1.234,56" → 1234.56, "1,234.56" → 1234.56; a number without two places after its mark is no price.
    static func parseNumber(_ raw: String) -> Decimal? {
        var text = raw.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "'", with: "")
        let negative = text.hasPrefix("-")
        if negative { text.removeFirst() }
        guard let last = text.lastIndex(where: { $0 == "." || $0 == "," }) else { return Decimal(string: text) }
        let whole = text[..<last].filter(\.isNumber)
        let cents = text[text.index(after: last)...]
        guard cents.count == 2, cents.allSatisfy(\.isNumber), !whole.isEmpty else { return nil }
        guard let value = Decimal(string: "\(whole).\(cents)", locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return negative ? -value : value
    }

    /// An amount typed by hand ("119", "119,5", "1.234,56", "12.50") as a stored amount ("119.00 EUR"); nil when it is
    /// no number.
    static func typedAmount(_ input: String, currency: String?) -> String? {
        let text = input.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        guard !text.isEmpty else { return nil }
        var value = parseNumber(text)
        if value == nil {
            // One place after the mark, or none: "119,5", "119".
            let plain = text.replacingOccurrences(of: ",", with: ".")
            guard plain.filter({ $0 == "." }).count <= 1, plain.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
            value = Decimal(string: plain, locale: Locale(identifier: "en_US_POSIX"))
        }
        guard let value else { return nil }
        let formatted = format(value)
        return currency.map { formatted + " " + $0 } ?? formatted
    }

    // MARK: Sender

    /// Legal forms that end a company's name ("Muster AG"). Not "KG": on a receipt it is a weight.
    private static let legalFormWords: Set<String> = ["gmbh", "ag", "ohg", "se", "ug", "mbh", "gbr", "ltd", "inc", "llc", "plc"]
    /// Words of a company, an office or a bank anywhere in a name ("Stadtsparkasse", "Finanzamt").
    private static let organizationParts = [
        "gmbh", "e.v.", "sparkasse", "bank", "versicherung", "stadtwerke", "finanzamt", "krankenkasse", "behörde", "insurance",
        "universit", "telekom", "vodafone",
    ]

    /// The company or office the document comes from: the first line of its head that names one. On a letter it is the
    /// small sender line above the address ("Muster GmbH · Hauptstr. 1 · 12345 Berlin"), on a receipt the shop's name
    /// at the top. Nil when none is clear.
    static func correspondent(in text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for line in lines.prefix(25) {
            let name = firstPart(of: line)
            // "Bankverbindung: …" is a field, not a name; a line with a price or a number is an item or an address.
            guard name.count >= 3, name.count <= 60, name.contains(where: \.isLetter), !name.contains(":"),
                  !name.contains(where: \.isNumber),
                  number.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil else { continue }
            let lower = name.lowercased()
            if organizationParts.contains(where: lower.contains) { return name }
            // A legal form only as the last word after a name that starts with a capital: "Muster AG".
            let words = name.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
            if words.count >= 2, let last = words.last, legalFormWords.contains(last.lowercased()),
               words.first?.first?.isUppercase == true {
                return name
            }
        }
        return nil
    }

    /// The part of a letterhead line before its address: "Muster GmbH · Hauptstr. 1" → "Muster GmbH".
    static func firstPart(of line: String) -> String {
        var part = line
        for separator in [" · ", " • ", " | ", " - ", " – ", ", ", "\t"] {
            if let range = part.range(of: separator) { part = String(part[..<range.lowerBound]) }
        }
        return part.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "·•|-–,")))
    }

    // MARK: Matching senders

    private static let legalForms: Set<String> = [
        "gmbh", "ag", "kg", "ohg", "ev", "e", "v", "se", "ug", "mbh", "gbr", "co", "ltd", "inc", "llc", "plc", "corp", "the", "und", "and",
    ]

    /// A sender as it is compared: lowercased, without accents, punctuation and legal form, so "Telekom Deutschland
    /// GmbH" and "telekom deutschland" are the same.
    static func correspondentKey(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && !legalForms.contains($0) }
        return words.joined(separator: " ")
    }
}

/// The line the summary's model writes about a document: "DOCUMENT: invoice | 2026-03-02 | Telekom | 119.00 EUR".
enum DocumentLine {
    /// The kind a word the model wrote names (also German: "Rechnung", "Vertrag"); nil for one that is not known.
    static func kindWord(_ word: String) -> DocumentKind? { DocumentKind.named(word) }

    /// The line added to the prompt of a summary of a file or an image.
    static var prompt: String {
        let kinds = DocumentKind.allCases.map(\.rawValue).joined(separator: " | ")
        return "\nDOCUMENT: <kind, one of: \(kinds)> | <date of the document as YYYY-MM-DD, or \"none\"> | <sender: the company, office or person it comes from, or \"none\"> | <total amount as a number with a point and the currency code, like \"119.00 EUR\", or \"none\">"
    }

    /// Takes the "DOCUMENT:" line off an answer and reads it.
    static func split(_ text: String) -> (text: String, info: DocumentInfo?) {
        var lines = text.components(separatedBy: "\n")
        guard let index = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("DOCUMENT:") }) else {
            return (text, nil)
        }
        let line = lines.remove(at: index).trimmingCharacters(in: .whitespaces)
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), parse(String(line.dropFirst("DOCUMENT:".count))))
    }

    /// The fields of the line; "none" and empty ones stay unknown.
    static func parse(_ value: String) -> DocumentInfo? {
        let fields = value.split(separator: "|", omittingEmptySubsequences: false).map { field -> String? in
            let clean = field.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'*<>`"))
                .trimmingCharacters(in: .whitespaces)
            let lower = clean.lowercased()
            return clean.isEmpty || ["none", "unknown", "n/a", "-", "keine", "kein", "unbekannt"].contains(lower) ? nil : clean
        }
        guard !fields.isEmpty else { return nil }
        var info = DocumentInfo()
        // A kind the model made up says nothing: unknown, so the device's guess stays.
        if let kind = fields[0] { info.kind = kindWord(kind) }
        if fields.count > 1, let day = fields[1] { info.day = DocumentExtractor.dates(in: day).first }
        if fields.count > 2, let sender = fields[2], sender.count <= 80 { info.correspondent = sender }
        if fields.count > 3, let amount = fields[3] { info.amount = DocumentExtractor.amount(in: "total " + amount)?.value }
        return info.isEmpty ? nil : info
    }
}
