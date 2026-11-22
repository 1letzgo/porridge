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

    /// German and English words for each kind, singular and plural, besides the raw value: what a model writes
    /// for a kind, what a search or a chat question names it by.
    static let words: [String: DocumentKind] = {
        let lists: [(DocumentKind, [String])] = [
            (.invoice, ["rechnung", "rechnungen", "invoices", "bill", "bills", "faktura", "fakturen", "mahnung", "mahnungen",
                        "zahlungserinnerung", "zahlungserinnerungen", "payment reminder", "payment reminders"]),
            (.receipt, ["quittung", "quittungen", "kassenbon", "kassenbons", "kassenbeleg", "kassenbelege", "beleg", "belege", "bon", "bons", "receipts"]),
            (.contract, ["vertrag", "verträge", "vertraege", "vereinbarung", "vereinbarungen", "contracts", "agreement", "agreements"]),
            (.letter, ["brief", "briefe", "schreiben", "anschreiben", "letters"]),
            (.statement, ["kontoauszug", "kontoauszüge", "kontoauszuege", "auszug", "auszüge", "statements"]),
            (.payslip, ["gehaltsabrechnung", "gehaltsabrechnungen", "lohnabrechnung", "lohnabrechnungen", "entgeltabrechnung",
                        "entgeltabrechnungen", "lohnzettel", "payslips", "pay slip", "pay slips"]),
            (.notice, ["bescheid", "bescheide", "steuerbescheid", "steuerbescheide", "official notice", "notices"]),
            (.certificate, ["bescheinigung", "bescheinigungen", "zeugnis", "zeugnisse", "zertifikat", "zertifikate", "urkunde", "urkunden", "certificates"]),
            (.offer, ["angebot", "angebote", "kostenvoranschlag", "kostenvoranschläge", "quote", "quotes", "quotation", "quotations", "offers"]),
            (.insurance, ["versicherung", "versicherungen", "versicherungsschein", "versicherungsscheine", "police", "policen", "policy", "policies", "insurances"]),
            (.other, ["sonstiges", "andere", "anderes"]),
        ]
        var words: [String: DocumentKind] = [:]
        for (kind, list) in lists { for word in list { words[word] = kind } }
        return words
    }()

    /// The kind a word names ("Rechnungen", "contract", "Quittung"); nil for one that is not known.
    static func named(_ word: String) -> DocumentKind? {
        let key = word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return DocumentKind(rawValue: key) ?? words[key]
    }

    /// Kinds whose amount is worth showing: what was paid, is to be paid, or was offered.
    var hasAmount: Bool {
        switch self {
        case .invoice, .receipt, .statement, .payslip, .notice, .offer, .insurance: true
        case .contract, .letter, .certificate, .other: false
        }
    }

    /// Kinds that ask for a payment, so they can be open, overdue or paid: invoices (reminders are invoices too),
    /// official notices (a tax demand) and insurance (a premium invoice).
    var asksForPayment: Bool {
        switch self {
        case .invoice, .notice, .insurance: true
        default: false
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
    /// The day it has to be paid by ("zahlbar bis"), "yyyy-MM-dd" like `day`. Read from the paper or set by hand.
    var dueDay: String?
    /// Marked as paid by hand. Nil is "not paid" (or never looked at): no reading sets it.
    var isPaid: Bool?
    /// The day it was marked as paid, "yyyy-MM-dd".
    var paidDay: String?

    init(
        kind: DocumentKind? = nil, day: String? = nil, correspondent: String? = nil, amount: String? = nil, isEdited: Bool? = nil,
        dueDay: String? = nil, isPaid: Bool? = nil, paidDay: String? = nil
    ) {
        kindRaw = kind?.rawValue
        self.day = day
        self.correspondent = correspondent
        self.amount = amount
        self.isEdited = isEdited
        self.dueDay = dueDay
        self.isPaid = isPaid
        self.paidDay = paidDay
    }

    var kind: DocumentKind? {
        get { kindRaw.flatMap(DocumentKind.init(rawValue:)) }
        set { kindRaw = newValue?.rawValue }
    }

    var edited: Bool { isEdited == true }

    /// Nothing known about the document.
    var isEmpty: Bool { kind == nil && day == nil && correspondent == nil && amount == nil && dueDay == nil && !paid }

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
        if let dueDay = other.dueDay { result.dueDay = dueDay }
        // Paid is only ever set by hand: what knows it keeps it.
        if other.paid {
            result.isPaid = true
            result.paidDay = other.paidDay ?? result.paidDay
        }
        return result
    }

    // MARK: Payment

    /// Whether a document that asks for a payment is paid or still to be paid.
    enum PaymentStatus: String, Codable, CaseIterable {
        case open, overdue, paid
    }

    var paid: Bool { isPaid == true }

    /// A paper that can be marked as paid: one of a kind that asks for payment, or one whose kind says nothing.
    var canBePaid: Bool { kind.map { $0.asksForPayment || $0 == .other } ?? true }

    /// The payment is followed: a paper that can be paid, with a due day or marked as paid. An old invoice with
    /// neither has no state (most likely it was paid long ago), so nothing turns "open" by itself.
    var tracksPayment: Bool { canBePaid && (dueDay != nil || paid) }

    /// A single document's menu offers "Mark as Paid": a bill (or a paper of another kind whose payment is followed).
    var offersPaid: Bool { kind?.asksForPayment == true || tracksPayment }

    /// The due day as a date at noon.
    var dueDate: Date? { DocumentInfo.date(fromDay: dueDay) }

    /// Open, overdue (its due day has passed) or paid; nil for a document whose payment is not followed.
    func paymentStatus(now: Date = Date(), calendar: Calendar = DocumentInfo.calendar) -> PaymentStatus? {
        guard tracksPayment else { return nil }
        if paid { return .paid }
        if let dueDay, dueDay < DocumentInfo.dayKey(now, calendar: calendar) { return .overdue }
        return .open
    }

    /// Still to be paid, due or overdue: for filters and questions.
    var isOpen: Bool { tracksPayment && !paid }

    /// Still to be paid and its due day has passed.
    func isOverdue(now: Date = Date(), calendar: Calendar = DocumentInfo.calendar) -> Bool {
        paymentStatus(now: now, calendar: calendar) == .overdue
    }

    /// Whether the payment is in the state a filter asks for; "open" takes overdue ones too.
    func matches(_ filter: PaymentStatus, now: Date = Date(), calendar: Calendar = DocumentInfo.calendar) -> Bool {
        guard let status = paymentStatus(now: now, calendar: calendar) else { return false }
        return filter == .open ? status != .paid : status == filter
    }

    /// How long a due day read automatically may lie in the past: a paper due longer ago is from the archive (scanned
    /// late, most likely paid), so it does not turn up as overdue.
    static let staleDueDays = 30

    /// Without a due day that was read automatically and is long past (`staleDueDays`). Not for what was set by hand.
    func droppingStaleDueDay(now: Date = Date(), calendar: Calendar = DocumentInfo.calendar) -> DocumentInfo {
        guard let dueDay, let limit = calendar.date(byAdding: .day, value: -DocumentInfo.staleDueDays, to: now),
              dueDay < DocumentInfo.dayKey(limit, calendar: calendar) else { return self }
        var copy = self
        copy.dueDay = nil
        return copy
    }

    /// Marks it as paid (on the day given, else the day it was marked before, else today) or as not paid.
    mutating func setPaid(_ isPaid: Bool, on day: String? = nil, now: Date = Date()) {
        self.isPaid = isPaid ? true : nil
        paidDay = isPaid ? (day ?? paidDay ?? DocumentInfo.dayKey(now)) : nil
    }

    /// The state for the chip: "Open · due 12 Dec", "Overdue", "Paid"; nil without one.
    func paymentLabel(now: Date = Date()) -> String? {
        switch paymentStatus(now: now) {
        case .open:
            guard let dueDate else { return String(localized: "Open") }
            return String(localized: "Open · due \(dueDate.formatted(.dateTime.day().month(.abbreviated)))")
        case .overdue: return String(localized: "Overdue")
        case .paid: return String(localized: "Paid")
        case nil: return nil
        }
    }

    /// The words of a search or a question that ask for a state of payment, German and English. The "open" and
    /// "overdue" words are shared with to-dos (`ChatQuery` tells them apart by a document kind beside them).
    static let paymentWords: [String: PaymentStatus] = {
        let lists: [(PaymentStatus, [String])] = [
            (.open, ["offen", "offene", "offenen", "offener", "offenes", "open", "unbezahlt", "unbezahlte", "unbezahlten", "unbezahlter",
                     "unbezahltes", "unpaid", "outstanding", "ausstehend", "ausstehende", "ausstehenden"]),
            (.overdue, ["überfällig", "überfällige", "überfälligen", "überfälliger", "überfälliges", "ueberfaellig", "overdue"]),
            (.paid, ["bezahlt", "bezahlte", "bezahlten", "bezahlter", "bezahltes", "beglichen", "beglichene", "beglichenen", "paid", "settled"]),
        ]
        var words: [String: PaymentStatus] = [:]
        for (status, list) in lists { for word in list { words[word] = status } }
        return words
    }()

    /// Words that only ever mean a payment ("unbezahlt", "paid"), never the state of a to-do.
    static let strictPaymentWords: Set<String> = [
        "unbezahlt", "unbezahlte", "unbezahlten", "unbezahlter", "unbezahltes", "unpaid", "outstanding",
        "bezahlt", "bezahlte", "bezahlten", "bezahlter", "bezahltes", "beglichen", "beglichene", "beglichenen", "paid", "settled",
    ]

    /// The state of payment a word asks for ("unbezahlte", "Overdue"); nil for any other word.
    static func paymentStatus(named word: String) -> PaymentStatus? {
        paymentWords[word.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))]
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
        if let paymentLabel = paymentLabel() { parts.append(paymentLabel) }
        return parts.joined(separator: " · ")
    }

    /// A short name for a chip: "Invoice · Telekom", the sender alone without a kind, "Document" without either.
    var shortLabel: String {
        let parts = [kind?.title, correspondent].compactMap { $0 }
        return parts.isEmpty ? String(localized: "Document") : parts.joined(separator: " · ")
    }

    /// The document in a sentence, for the chat's passages: "Invoice from Telekom, dated 2 Mar 2026, amount 119,00 €".
    var sentence: String {
        var text = (kind ?? .other).title
        if let correspondent { text += " from " + correspondent }
        if let dayText { text += ", dated " + dayText }
        if let amountText { text += ", amount " + amountText }
        if tracksPayment, let dueDate { text += ", payable by " + dueDate.formatted(date: .abbreviated, time: .omitted) }
        if paid { text += ", paid" + (DocumentInfo.date(fromDay: paidDay).map { " on " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "") }
        return text
    }

    /// The words a search finds the document by.
    var searchText: String {
        [kind?.title, kind?.rawValue, correspondent, day, amount, amountText].compactMap { $0 }.joined(separator: " ")
    }
}
