import Foundation

/// An e-mail read from its source (an .eml file, RFC 5322 with MIME): who sent it, to whom, when, its subject, its
/// text and its attachments. Pure Foundation and free of the store, so it can be read anywhere and tested.
///
/// The source is read byte for byte as ISO Latin 1 (every byte one character, nothing lost); each part's bytes are
/// decoded with its own transfer encoding and charset once it is clear what it is.
struct MailMessage: Equatable {
    struct Address: Equatable {
        var name: String?
        var email: String

        /// "Telekom <rechnung@telekom.de>", or the address alone.
        var display: String {
            guard let name, !name.isEmpty, name != email else { return email }
            return "\(name) <\(email)>"
        }

        /// Who sent it, for a person: the name, or the domain of the address without one ("telekom.de").
        var senderName: String {
            if let name, !name.isEmpty, !name.contains("@") { return name }
            guard let at = email.lastIndex(of: "@") else { return email }
            return String(email[email.index(after: at)...])
        }
    }

    struct Attachment: Equatable {
        var name: String
        var mimeType: String
        var data: Data
        /// A picture the HTML of the mail shows (`cid:`): a logo, a picture in the signature, or a photo put in the text.
        var isInline: Bool
        var contentID: String?
    }

    var subject: String = ""
    var from: Address?
    var to: [Address] = []
    var cc: [Address] = []
    var date: Date?
    var messageID: String?
    /// The text of the mail: its plain part, or its HTML part as text.
    var body: String = ""
    /// Every attached file, inline pictures included (see `files`).
    var attachments: [Attachment] = []

    /// Pictures the HTML shows that are at most this big are decoration (logos, icons, signatures), not photos.
    static let decorationBytes = 100_000

    /// The files worth keeping: attachments without the small pictures the HTML shows (logos, signatures) and
    /// without signatures of the mail itself. A photo put in the text is kept.
    var files: [Attachment] {
        attachments.filter { attachment in
            let type = attachment.mimeType.lowercased()
            if type == "application/pkcs7-signature" || type == "application/x-pkcs7-signature" || type == "application/pgp-signature" { return false }
            if attachment.isInline, type.hasPrefix("image/"), attachment.data.count <= Self.decorationBytes { return false }
            return true
        }
    }
}

// MARK: - Reading

extension MailMessage {
    /// Reads a mail from its source. Throws only when the data is no mail at all (no header).
    static func parse(_ data: Data) throws -> MailMessage {
        let raw = latin1String(data)
        let part = MIMEPart(raw: raw, depth: 0, budget: MIMEPart.Budget())
        guard !part.headers.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        var message = MailMessage()
        message.subject = MIMEHeader.decodeWords(part.header("subject") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        message.from = part.header("from").flatMap { MIMEHeader.addresses($0).first }
        message.to = part.header("to").map(MIMEHeader.addresses) ?? []
        message.cc = part.header("cc").map(MIMEHeader.addresses) ?? []
        message.date = part.header("date").flatMap(MIMEHeader.date)
        message.messageID = part.header("message-id")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))

        var plain: [String] = []
        var html: [String] = []
        collect(part, plain: &plain, html: &html, attachments: &message.attachments)
        // Pictures any HTML form of the mail shows (also one not taken for the text).
        let shown = htmlSources(of: part).joined()
        for index in message.attachments.indices {
            if let id = message.attachments[index].contentID, !id.isEmpty, shown.contains("cid:" + id) {
                message.attachments[index].isInline = true
            }
        }
        let text = plain.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        message.body = text.isEmpty ? HTMLText.plain(html.joined(separator: "\n")) : MailMessage.normalizedLines(text)
        return message
    }

    static func parse(contentsOf url: URL) throws -> MailMessage {
        try parse(Data(contentsOf: url))
    }

    /// The HTML of every part, for the pictures it shows.
    private static func htmlSources(of part: MIMEPart) -> [String] {
        if part.contentType.hasPrefix("multipart/") { return part.children.flatMap(htmlSources) }
        return part.contentType == "text/html" && !part.isAttachment ? [part.text] : []
    }

    /// Walks the parts: the text of the first readable alternative, the attachments of all.
    private static func collect(_ part: MIMEPart, plain: inout [String], html: inout [String], attachments: inout [Attachment]) {
        let type = part.contentType
        if type.hasPrefix("multipart/") {
            let children = part.children
            if type == "multipart/alternative" {
                // One text in several forms: plain text when there is one, otherwise the richest form.
                if let text = children.first(where: { $0.contentType == "text/plain" && !$0.isAttachment }) {
                    plain.append(text.text)
                } else if let rich = children.last(where: { $0.contentType == "text/html" || $0.contentType.hasPrefix("multipart/") }) {
                    collect(rich, plain: &plain, html: &html, attachments: &attachments)
                }
                // Attachments hidden in other alternatives (rare) still count.
                for child in children where child.isAttachment { collect(child, plain: &plain, html: &html, attachments: &attachments) }
                return
            }
            for child in children { collect(child, plain: &plain, html: &html, attachments: &attachments) }
            return
        }
        if !part.isAttachment, type == "text/plain" || part.headers.isEmpty {
            plain.append(part.text)
            return
        }
        if !part.isAttachment, type == "text/html" {
            html.append(part.text)
            return
        }
        // Anything else is a file: a forwarded mail (message/rfc822) is kept as an .eml of its own.
        attachments.append(Attachment(
            name: part.fileName ?? defaultName(for: type, index: attachments.count + 1),
            mimeType: type,
            data: part.decodedData,
            isInline: false,
            contentID: part.header("content-id")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
        ))
    }

    private static func defaultName(for type: String, index: Int) -> String {
        if type == "message/rfc822" { return "Forwarded Message \(index).eml" }
        let ext: String = switch type {
        case "application/pdf": "pdf"
        case "image/jpeg", "image/jpg": "jpg"
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/heic": "heic"
        case "text/calendar": "ics"
        case "text/html": "html"
        case "text/plain": "txt"
        default: "bin"
        }
        return "Attachment \(index).\(ext)"
    }

    /// Line ends as "\n", no trailing spaces, at most one empty line in a row.
    static func normalizedLines(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").map { line in
                var line = line
                while line.last == " " || line.last == "\t" { line.removeLast() }
                return line
            }
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) { result.append(line) }
        while result.last?.isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n")
    }
}

/// Bytes as ISO Latin 1: every byte the character of the same number, so nothing is lost.
private func latin1String(_ data: Data) -> String {
    String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
}

/// The bytes of a Latin 1 string back (each character one byte).
private func latin1Bytes(_ text: some StringProtocol) -> Data {
    Data(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
}

// MARK: - Parts

/// One part of a mail (or the mail itself): its headers and its body, still as Latin 1 text.
struct MIMEPart {
    /// How deep parts may nest, and how many there may be in one mail: a mail built to nest without end is read
    /// up to here, in time that grows with its size only.
    static let maxDepth = 20
    static let maxParts = 500

    /// The parts read so far in one mail.
    final class Budget {
        var parts = 0
    }

    /// Names lowercased, values unfolded, in order.
    let headers: [(name: String, value: String)]
    let body: String
    /// The parts of a multipart, split at its boundary once (empty below `maxDepth` or past `maxParts`).
    let children: [MIMEPart]

    init(raw: String) {
        self.init(raw: raw, depth: 0, budget: Budget())
    }

    init(raw: String, depth: Int, budget: Budget) {
        // The header ends at the first empty line; "\r\n" and "\n" alike, whichever comes first.
        var headerText = raw
        var bodyText = ""
        let ends = [raw.range(of: "\r\n\r\n"), raw.range(of: "\n\n")].compactMap { $0 }
        if let first = ends.min(by: { $0.lowerBound < $1.lowerBound }) {
            headerText = String(raw[..<first.lowerBound])
            bodyText = String(raw[first.upperBound...])
        }
        // A part without headers starts with its empty line, or has none at all and is only a body.
        if headerText.hasPrefix("\r\n") || headerText.hasPrefix("\n") || !MIMEPart.looksLikeHeader(headerText) {
            headers = []
            // "\r\n" is one character to Swift, like "\n".
            body = raw.hasPrefix("\r\n") || raw.hasPrefix("\n") ? String(raw.dropFirst()) : raw
            children = []
            return
        }
        let parsed = MIMEPart.parseHeaders(headerText)
        headers = parsed
        body = bodyText
        let contentType = parsed.first { $0.name == "content-type" }?.value ?? ""
        if MIMEHeader.mainValue(contentType).lowercased().hasPrefix("multipart/"), depth < Self.maxDepth,
           let boundary = MIMEHeader.parameters(contentType)["boundary"], !boundary.isEmpty {
            children = Self.split(bodyText, boundary: boundary, depth: depth + 1, budget: budget)
        } else {
            children = []
        }
    }

    private static func looksLikeHeader(_ text: String) -> Bool {
        guard let first = text.split(whereSeparator: \.isNewline).first, let colon = first.firstIndex(of: ":") else { return false }
        let name = first[..<colon]
        return !name.isEmpty && !name.contains(" ") && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func parseHeaders(_ text: String) -> [(name: String, value: String)] {
        var result: [(name: String, value: String)] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if let first = line.first, first == " " || first == "\t" {
                // A folded line continues the header before it.
                guard !result.isEmpty else { continue }
                result[result.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                result.append((name, MIMEHeader.utf8IfPossible(value)))
            }
        }
        return result
    }

    func header(_ name: String) -> String? {
        headers.first { $0.name == name }?.value
    }

    var contentType: String {
        guard let value = header("content-type") else { return "text/plain" }
        return MIMEHeader.mainValue(value).lowercased()
    }

    var parameters: [String: String] {
        MIMEHeader.parameters(header("content-type") ?? "")
    }

    var disposition: String? {
        header("content-disposition").map { MIMEHeader.mainValue($0).lowercased() }
    }

    /// A file rather than the text of the mail: marked as an attachment, or named.
    var isAttachment: Bool {
        if disposition == "attachment" { return true }
        let type = contentType
        if type.hasPrefix("multipart/") { return false }
        // The text of the mail, unless it comes as a named file of its own.
        if type == "text/plain" || type == "text/html" { return fileName != nil && disposition != "inline" }
        // Pictures, PDFs, calendars, forwarded mails: files (inline pictures are sorted out by `MailMessage.files`).
        return true
    }

    var fileName: String? {
        let disposition = header("content-disposition").map(MIMEHeader.parameters) ?? [:]
        let name = disposition["filename"] ?? parameters["name"]
        guard let name else { return nil }
        let clean = MIMEHeader.decodeWords(name).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    /// The parts of a multipart body, split at its boundary.
    private static func split(_ body: String, boundary: String, depth: Int, budget: Budget) -> [MIMEPart] {
        let delimiter = "--" + boundary
        var parts: [MIMEPart] = []
        var current: [String] = []
        var started = false
        func add() {
            guard budget.parts < maxParts else { return }
            budget.parts += 1
            parts.append(MIMEPart(raw: joined(current), depth: depth, budget: budget))
        }
        // Split by Foundation: to Swift "\r\n" is one character, not a "\n".
        let lines = body.components(separatedBy: "\n")
        for line in lines {
            if budget.parts >= maxParts { break }
            let bare = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if bare == delimiter + "--" {
                if started { add() }
                started = false
                current = []
                break
            }
            if bare == delimiter {
                if started { add() }
                started = true
                current = []
                continue
            }
            if started { current.append(line) }
        }
        // A mail cut off before its closing boundary keeps its last part.
        if started, !current.isEmpty { add() }
        return parts
    }

    /// The lines of a part; the line end before the next boundary belongs to the boundary.
    private static func joined(_ lines: [String]) -> String {
        var text = lines.joined(separator: "\n")
        if text.hasSuffix("\r") { text.removeLast() }
        return text
    }

    /// The body's bytes, undone from its transfer encoding.
    var decodedData: Data {
        let encoding = (header("content-transfer-encoding") ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        switch encoding {
        case "base64":
            let clean = body.filter { !$0.isWhitespace }
            // Some senders leave out the padding.
            let padded = clean + String(repeating: "=", count: (4 - clean.count % 4) % 4)
            return Data(base64Encoded: padded, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            return MIMEHeader.quotedPrintable(body, isHeader: false)
        default:
            // 7bit, 8bit, binary: the bytes as they are, without the line end before the next boundary.
            var text = Substring(body)
            // "\r\n" is one character to Swift.
            if text.hasSuffix("\r\n") || text.hasSuffix("\n") { text = text.dropLast() }
            return latin1Bytes(text)
        }
    }

    /// The body as text, in its charset.
    var text: String {
        MIMEHeader.decode(decodedData, charset: parameters["charset"])
    }
}

// MARK: - Header values

enum MIMEHeader {
    /// "text/plain; charset=utf-8" → "text/plain".
    static func mainValue(_ value: String) -> String {
        String(value.split(separator: ";", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// The parameters of a header value, names lowercased; quoted values unquoted, RFC 2231 values (`name*=`,
    /// `name*0*=`) decoded and joined.
    static func parameters(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        var continued: [String: [(Int, String, Bool)]] = [:]
        for piece in splitParameters(value).dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            var name = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var raw = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
                raw = String(raw.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            let extended = name.hasSuffix("*")
            if extended { name.removeLast() }
            // "filename*0*", "filename*1": pieces of one value.
            if let star = name.firstIndex(of: "*"), let index = Int(name[name.index(after: star)...]) {
                continued[String(name[..<star]), default: []].append((index, raw, extended))
                continue
            }
            result[name] = extended ? decodeExtended(raw) : raw
        }
        for (name, pieces) in continued {
            let sorted = pieces.sorted { $0.0 < $1.0 }
            // Only the first piece names the charset; every encoded piece is percent-encoded in it.
            var charset = "utf-8"
            var bytes = Data()
            for (offset, piece) in sorted.enumerated() {
                var value = piece.1
                if piece.2, offset == 0 {
                    let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    if parts.count == 3 {
                        charset = String(parts[0]).isEmpty ? charset : String(parts[0])
                        value = String(parts[2])
                    }
                }
                bytes += piece.2 ? percentDecoded(value) : latin1Bytes(value)
            }
            result[name] = decode(bytes, charset: charset)
        }
        return result
    }

    /// Splits at ";" outside quotes.
    private static func splitParameters(_ value: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in value {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\", quoted { current.append(character); escaped = true; continue }
            if character == "\"" { quoted.toggle() }
            if character == ";", !quoted {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        pieces.append(current)
        return pieces
    }

    /// "utf-8''Rechnung%20M%C3%A4rz.pdf" → "Rechnung März.pdf".
    static func decodeExtended(_ value: String) -> String {
        let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return decode(percentDecoded(value), charset: "utf-8") }
        return decode(percentDecoded(String(parts[2])), charset: parts[0].isEmpty ? "utf-8" : String(parts[0]))
    }

    private static func percentDecoded(_ value: String) -> Data {
        var bytes: [UInt8] = []
        let scalars = Array(value.unicodeScalars)
        var index = 0
        while index < scalars.count {
            if scalars[index] == "%", index + 2 < scalars.count, let byte = UInt8(String(scalars[index + 1]) + String(scalars[index + 2]), radix: 16) {
                bytes.append(byte)
                index += 3
            } else {
                bytes.append(UInt8(truncatingIfNeeded: scalars[index].value))
                index += 1
            }
        }
        return Data(bytes)
    }

    /// A header written in 8 bit (raw UTF-8, RFC 6532) is read as UTF-8; otherwise it stays as it was.
    static func utf8IfPossible(_ latin1: String) -> String {
        guard latin1.unicodeScalars.contains(where: { $0.value > 127 }) else { return latin1 }
        return String(data: latin1Bytes(latin1), encoding: .utf8) ?? latin1
    }

    /// Bytes in a charset as text; an unknown or wrong charset falls back to UTF-8, then Windows-1252.
    static func decode(_ data: Data, charset: String?) -> String {
        if let charset, let encoding = encoding(named: charset), let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .windowsCP1252) ?? latin1String(data)
    }

    static func encoding(named charset: String) -> String.Encoding? {
        let name = charset.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased()
        switch name {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii": return .utf8
        case "iso-8859-1", "latin1", "latin-1": return .windowsCP1252
        default: break
        }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    // MARK: Encoded words

    private static let encodedWord = try! NSRegularExpression(pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?\s]*)\?="#)

    /// Undoes RFC 2047 encoded words ("=?UTF-8?Q?M=C3=A4rz?="); white space between two of them goes.
    static func decodeWords(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        let ns = value as NSString
        let matches = encodedWord.matches(in: value, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return value }
        var result = ""
        var cursor = 0
        var lastWasWord = false
        // Neighbouring words of one charset are joined as bytes first: a character may be split between them.
        var pending = Data()
        var pendingCharset: String?
        func flush() {
            if let charset = pendingCharset { result += decode(pending, charset: charset) }
            pending = Data()
            pendingCharset = nil
        }
        for match in matches {
            let between = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if !(lastWasWord && between.allSatisfy(\.isWhitespace)) {
                flush()
                result += between
            }
            let charset = ns.substring(with: match.range(at: 1)).split(separator: "*").first.map(String.init) ?? "utf-8"
            let mode = ns.substring(with: match.range(at: 2)).lowercased()
            let text = ns.substring(with: match.range(at: 3))
            let bytes: Data
            if mode == "b" {
                let padded = text + String(repeating: "=", count: (4 - text.count % 4) % 4)
                bytes = Data(base64Encoded: padded) ?? Data()
            } else {
                bytes = quotedPrintable(text, isHeader: true)
            }
            if pendingCharset != nil, pendingCharset?.lowercased() != charset.lowercased() { flush() }
            pendingCharset = charset
            pending += bytes
            cursor = match.range.location + match.range.length
            lastWasWord = true
        }
        flush()
        result += ns.substring(from: cursor)
        return result
    }

    /// Quoted-printable to bytes. In a header "_" is a space.
    static func quotedPrintable(_ text: String, isHeader: Bool) -> Data {
        var bytes: [UInt8] = []
        let source = Array(text.unicodeScalars)
        var index = 0
        func hex(_ scalar: Unicode.Scalar) -> UInt8? {
            switch scalar.value {
            case 48...57: UInt8(scalar.value - 48)
            case 65...70: UInt8(scalar.value - 55)
            case 97...102: UInt8(scalar.value - 87)
            default: nil
            }
        }
        while index < source.count {
            let scalar = source[index]
            if scalar == "=" {
                // A soft line break: "=" at the end of a line.
                if index + 1 < source.count, source[index + 1] == "\n" { index += 2; continue }
                if index + 2 < source.count, source[index + 1] == "\r", source[index + 2] == "\n" { index += 3; continue }
                if index + 2 < source.count, let high = hex(source[index + 1]), let low = hex(source[index + 2]) {
                    bytes.append(high << 4 | low)
                    index += 3
                    continue
                }
                if index + 1 == source.count { index += 1; continue }
            }
            if isHeader, scalar == "_" {
                bytes.append(0x20)
            } else {
                bytes.append(UInt8(truncatingIfNeeded: scalar.value))
            }
            index += 1
        }
        return Data(bytes)
    }

    // MARK: Addresses

    /// "Max Muster <max@example.com>, "Doe, Jane" <jane@example.com>, bob@example.com".
    static func addresses(_ value: String) -> [MailMessage.Address] {
        var pieces: [String] = []
        var current = ""
        var quoted = false
        var angle = false
        for character in value {
            if character == "\"" { quoted.toggle() }
            if !quoted, character == "<" { angle = true }
            if !quoted, character == ">" { angle = false }
            if character == ",", !quoted, !angle {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        pieces.append(current)
        return pieces.compactMap(address)
    }

    static func address(_ raw: String) -> MailMessage.Address? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            let email = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            var name = text[..<open].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
            name = decodeWords(name).replacingOccurrences(of: "\\\"", with: "\"").trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
            return MailMessage.Address(name: name.isEmpty ? nil : name, email: email)
        }
        // "max@example.com (Max Muster)"
        if let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close {
            let email = text[..<open].trimmingCharacters(in: .whitespaces)
            let name = decodeWords(String(text[text.index(after: open)..<close])).trimmingCharacters(in: .whitespaces)
            return MailMessage.Address(name: name.isEmpty ? nil : name, email: email)
        }
        return MailMessage.Address(name: nil, email: decodeWords(text))
    }

    // MARK: Dates

    private static let dateFormats = [
        "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z",
        "EEE, d MMM yy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss zzz",
    ]

    /// "Tue, 3 Mar 2026 10:15:00 +0100 (CET)".
    static func date(_ value: String) -> Date? {
        var text = value.trimmingCharacters(in: .whitespaces)
        // A comment in brackets at the end: "(CET)".
        if let open = text.lastIndex(of: "("), text.hasSuffix(")") { text = text[..<open].trimmingCharacters(in: .whitespaces) }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in dateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return ISO8601DateFormatter().date(from: text)
    }
}

// MARK: - HTML

/// The text of an HTML mail, for reading and searching: paragraphs and line breaks kept, lists as "- ", links as
/// their text, everything else (styles, scripts, tags, comments) gone and entities resolved.
enum HTMLText {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static let dropped = regex(#"<!--.*?-->|<(head|style|script|title)\b[^>]*>.*?</\1\s*>"#)
    private static let lineBreak = regex(#"<br\s*/?>"#)
    private static let blockEnd = regex(#"</(p|div|h[1-6]|tr|table|blockquote|ul|ol|section|article|header|footer)\s*>|<(p|div|h[1-6]|table|blockquote|hr)\b[^>]*>"#)
    private static let listItem = regex(#"<li\b[^>]*>"#)
    private static let cellEnd = regex(#"</t[dh]\s*>"#)
    private static let tag = regex(#"<[^>]+>"#)
    private static let entity = try! NSRegularExpression(pattern: #"&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);"#)

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "auml": "ä", "ouml": "ö", "uuml": "ü",
        "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß", "euro": "€", "copy": "©", "reg": "®", "trade": "™",
        "ndash": "–", "mdash": "—", "hellip": "…", "laquo": "«", "raquo": "»", "bdquo": "„", "ldquo": "“", "rdquo": "”",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "middot": "·", "bull": "•", "eacute": "é", "egrave": "è", "agrave": "à",
        "aacute": "á", "ccedil": "ç", "zwnj": "", "zwj": "", "shy": "", "thinsp": " ", "ensp": " ", "emsp": " ",
    ]

    static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "\r\n", with: "\n")
        text = replace(dropped, in: text, with: "")
        // White space in HTML source is one space; only tags make lines.
        text = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        text = replace(lineBreak, in: text, with: "\n")
        text = replace(listItem, in: text, with: "\n- ")
        text = replace(cellEnd, in: text, with: " ")
        text = replace(blockEnd, in: text, with: "\n\n")
        text = replace(tag, in: text, with: "")
        text = decodeEntities(text)
        let lines = text.components(separatedBy: "\n").map { line in
            line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
        return MailMessage.normalizedLines(lines.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in entity.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let name = ns.substring(with: match.range(at: 1))
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = entities[name]
            }
            // A non-breaking space reads as a space.
            result += (replacement ?? ns.substring(with: match.range)).replacingOccurrences(of: "\u{00A0}", with: " ")
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }
}
