import Foundation

/// Loads a web page and cuts the readable text out of it.
enum LinkFetcher {
    struct Page {
        var title: String?
        var text: String
    }

    enum FetchError: LocalizedError {
        case badAddress
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .badAddress: "This is not a web address."
            case .failed(let message): message
            }
        }
    }

    static func fetch(_ address: String) async throws -> Page {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw FetchError.badAddress
        }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.failed("No answer from the server.") }
        guard (200..<300).contains(http.statusCode) else { throw FetchError.failed("The server answered \(http.statusCode).") }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard type.isEmpty || type.contains("html") || type.contains("text/plain") else {
            // PDFs, images and the like: nothing to read.
            return Page(title: nil, text: "")
        }
        let html = decode(data, contentType: type)
        return type.contains("text/plain") ? Page(title: nil, text: String(html.prefix(maxLength))) : extract(html)
    }

    private static let maxLength = 60_000

    private static func decode(_ data: Data, contentType: String) -> String {
        var encoding = String.Encoding.utf8
        if let range = contentType.range(of: "charset=") {
            let name = contentType[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            let cf = CFStringConvertIANACharSetNameToEncoding(String(name) as CFString)
            if cf != kCFStringEncodingInvalidId { encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
        }
        return String(data: data, encoding: encoding) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: HTML to text

    private static func replace(_ pattern: String, in text: String, with template: String = " ") -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func meta(_ property: String, in html: String) -> String? {
        firstMatch("<meta[^>]+(?:property|name)=[\"']\(property)[\"'][^>]+content=[\"']([^\"']*)[\"']", in: html)
            ?? firstMatch("<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+(?:property|name)=[\"']\(property)[\"']", in: html)
    }

    static func extract(_ html: String) -> Page {
        let rawTitle = meta("og:title", in: html) ?? firstMatch("<title[^>]*>(.*?)</title>", in: html)
        let title = rawTitle.map { clean(decodeEntities($0)) }.flatMap { $0.isEmpty ? nil : $0 }

        var body = html
        for tag in ["script", "style", "noscript", "svg", "template", "iframe", "nav", "footer", "header", "form", "aside"] {
            body = replace("<\(tag)\\b[^>]*>.*?</\(tag)>", in: body)
        }
        body = replace("<!--.*?-->", in: body)
        // The article itself, when the page marks it.
        for tag in ["article", "main"] {
            if let inner = firstMatch("<\(tag)\\b[^>]*>(.*?)</\(tag)>", in: body), inner.count > 600 {
                body = inner
                break
            }
        }
        body = replace("<br\\s*/?>", in: body, with: "\n")
        body = replace("</(p|div|h[1-6]|li|tr|blockquote|section|pre)>", in: body, with: "\n")
        body = replace("<[^>]+>", in: body, with: "")
        body = decodeEntities(body)

        var lines: [String] = []
        for raw in body.components(separatedBy: "\n") {
            let line = clean(raw)
            // Menus and buttons are short lines; keep sentences and longer headings.
            if line.count >= 25 || (line.count >= 8 && line.last?.isPunctuation == false && lines.last?.hasSuffix(":") == true) {
                lines.append(line)
            }
        }
        var text = lines.joined(separator: "\n\n")
        if text.count < 200, let description = meta("og:description", in: html) ?? meta("description", in: html) {
            let summary = clean(decodeEntities(description))
            if !summary.isEmpty { text = summary + (text.isEmpty ? "" : "\n\n" + text) }
        }
        return Page(title: title, text: String(text.prefix(maxLength)))
    }

    private static func clean(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß",
        "ndash": "–", "mdash": "—", "hellip": "…", "laquo": "«", "raquo": "»", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "euro": "€", "copy": "©", "middot": "·", "bull": "•",
        "eacute": "é", "egrave": "è", "agrave": "à", "ccedil": "ç", "aacute": "á", "oacute": "ó",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        guard let regex = try? NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);") else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var result = text
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result), let inner = Range(match.range(at: 1), in: result) else { continue }
            let name = String(result[inner])
            var replacement: String?
            if name.hasPrefix("#x"), let code = UInt32(name.dropFirst(2), radix: 16) {
                replacement = Unicode.Scalar(code).map { String(Character($0)) }
            } else if name.hasPrefix("#"), let code = UInt32(name.dropFirst()) {
                replacement = Unicode.Scalar(code).map { String(Character($0)) }
            } else {
                replacement = entities[name]
            }
            if let replacement { result.replaceSubrange(whole, with: replacement) }
        }
        return result
    }
}
