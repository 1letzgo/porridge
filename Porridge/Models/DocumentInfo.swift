import Foundation

/// What kind of paper a document is. Stored by its raw value, so new kinds can come without a change of the store.
enum DocumentKind: String, CaseIterable, Codable, Identifiable {
    case invoice
    case receipt
    case contract
    case letter
    case statement
    case payslip
    case notice
    case certificate
    case offer
    case insurance
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .invoice: String(localized: "Invoice")
        case .receipt: String(localized: "Receipt")
        case .contract: String(localized: "Contract")
        case .letter: String(localized: "Letter")
        case .statement: String(localized: "Statement")
        case .payslip: String(localized: "Payslip")
        case .notice: String(localized: "Official Notice")
        case .certificate: String(localized: "Certificate")
        case .offer: String(localized: "Quote")
        case .insurance: String(localized: "Insurance")
        case .other: String(localized: "Other")
        }
    }

    var symbol: String {
        switch self {
        case .invoice: "doc.text"
        case .receipt: "receipt"
        case .contract: "signature"
        case .letter: "envelope"
        case .statement: "list.bullet.rectangle"
        case .payslip: "banknote"
        case .notice: "building.columns"
        case .certificate: "checkmark.seal"
        case .offer: "tag"
        case .insurance: "umbrella"
        case .other: "doc"
        }
    }

    /// Kinds whose amount is worth showing: what was paid, is to be paid, or was offered.
    var hasAmount: Bool {
        switch self {
        case .invoice, .receipt, .statement, .payslip, .notice, .offer, .insurance: true
        case .contract, .letter, .certificate, .other: false
        }
    }
}

/// What a document is about, read out of it (on the device, and by the summary's model) or set by hand: its kind,
/// its date, who sent it and the amount. It is kept with the file it describes, inside the note's list of
/// attachments (`Attachment.document`), so it syncs with that list and needs no field of its own in the store.
struct DocumentInfo: Codable, Hashable {
    /// `DocumentKind` raw value.
    var kindRaw: String?
    /// The date on the document, "yyyy-MM-dd" (a calendar day, no time zone).
    var day: String?
    /// The company, office or person the document comes from.
    var correspondent: String?
    /// The total, "1234.56 EUR": a plain decimal with a point, then the currency code if one is known.
    var amount: String?
    /// Changed by hand: what is read automatically no longer replaces it.
    var isEdited: Bool?

    init(kind: DocumentKind? = nil, day: String? = nil, correspondent: String? = nil, amount: String? = nil, isEdited: Bool? = nil) {
        kindRaw = kind?.rawValue
        self.day = day
        self.correspondent = correspondent
        self.amount = amount
        self.isEdited = isEdited
    }

    var kind: DocumentKind? {
        get { kindRaw.flatMap(DocumentKind.init(rawValue:)) }
        set { kindRaw = newValue?.rawValue }
    }

    var edited: Bool { isEdited == true }

    /// Nothing known about the document.
    var isEmpty: Bool { kind == nil && day == nil && correspondent == nil && amount == nil }

    /// Says the paper is a document worth listing: a kind other than "other", or a sender.
    var isMeaningful: Bool { (kind != nil && kind != .other) || correspondent != nil }

    /// The date on the document as a day at noon in the current calendar; nil when there is none.
    var date: Date? { DocumentInfo.date(fromDay: day) }

    /// The fields of `other` that are known fill or replace these; `other` wins where it knows something. "Other"
    /// never replaces a kind that says more.
    func merged(with other: DocumentInfo) -> DocumentInfo {
        var result = self
        if let kind = other.kind, kind != .other || result.kind == nil { result.kind = kind }
        if let day = other.day { result.day = day }
        if let correspondent = other.correspondent { result.correspondent = correspondent }
        if let amount = other.amount { result.amount = amount }
        return result
    }

    // MARK: Days

    /// Day keys are Gregorian whatever calendar the device uses (Japanese, Buddhist …), in the device's time zone.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }()

    static func dayKey(_ date: Date, calendar: Calendar = DocumentInfo.calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func dayKey(year: Int, month: Int, day: Int) -> String? {
        guard (1900...2200).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        let calendar = Calendar(identifier: .gregorian)
        // 31 February is no day.
        guard let date = calendar.date(from: components), calendar.component(.day, from: date) == day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func date(fromDay day: String?, calendar: Calendar = DocumentInfo.calendar) -> Date? {
        guard let day else { return nil }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, dayKey(year: parts[0], month: parts[1], day: parts[2]) != nil else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 12
        return calendar.date(from: components)
    }

    // MARK: Amounts

    /// The value and currency of a stored amount ("119.00 EUR").
    static func parts(ofAmount amount: String?) -> (value: Decimal, currency: String?)? {
        guard let amount else { return nil }
        let pieces = amount.split(separator: " ")
        guard let first = pieces.first, let value = Decimal(string: String(first), locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return (value, pieces.count > 1 ? String(pieces[1]) : nil)
    }

    /// The amount as the user reads it, "119,00 €" in German.
    var amountText: String? {
        guard let (value, currency) = DocumentInfo.parts(ofAmount: amount) else { return amount }
        if let currency {
            return value.formatted(.currency(code: currency))
        }
        return value.formatted(.number.precision(.fractionLength(2)))
    }

    /// The date as the user reads it, "3 Mar 2026".
    var dayText: String? { date?.formatted(date: .abbreviated, time: .omitted) }

    /// One line about the document: "Invoice · Telekom · 119,00 € · 2 Mar 2026".
    var line: String {
        var parts: [String] = []
        if let kind, kind != .other || correspondent == nil { parts.append(kind.title) }
        if let correspondent { parts.append(correspondent) }
        if let amountText, kind?.hasAmount ?? true { parts.append(amountText) }
        if let dayText { parts.append(dayText) }
        return parts.joined(separator: " · ")
    }

    /// The document in a sentence, for the chat's passages: "Invoice from Telekom, dated 2 Mar 2026, amount 119,00 €".
    var sentence: String {
        var text = (kind ?? .other).title
        if let correspondent { text += " from " + correspondent }
        if let dayText { text += ", dated " + dayText }
        if let amountText { text += ", amount " + amountText }
        return text
    }

    /// The words a search finds the document by.
    var searchText: String {
        [kind?.title, kind?.rawValue, correspondent, day, amount, amountText].compactMap { $0 }.joined(separator: " ")
    }
}
