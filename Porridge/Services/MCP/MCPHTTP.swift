import Foundation
import Network

// The MCP server's transport: Streamable HTTP (MCP 2025-06-18) on 127.0.0.1 only, one endpoint `/mcp`, every
// request with the token as `Authorization: Bearer …`. Each POST carries one JSON-RPC message (or a batch) and is
// answered with JSON; the server opens no event streams (GET is answered 405, which the protocol allows).

struct HTTPRequest: Equatable {
    var method: String
    var path: String
    /// Header names in lowercase.
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct HTTPResponse: Equatable {
    var status: Int
    var headers: [(String, String)] = []
    var body = Data()

    static func == (a: HTTPResponse, b: HTTPResponse) -> Bool {
        a.status == b.status && a.body == b.body && a.headers.map { "\($0.0):\($0.1)" } == b.headers.map { "\($0.0):\($0.1)" }
    }

    static func json(_ data: Data, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: data)
    }

    static func text(_ status: Int, _ message: String, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")] + headers, body: Data((message + "\n").utf8))
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 431: "Request Header Fields Too Large"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }

    /// The bytes on the wire. The connection is closed after every answer.
    var serialized: Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// Reads an HTTP/1.1 request from the bytes received so far.
enum HTTPRequestParser {
    enum Outcome: Equatable {
        case incomplete
        case complete(HTTPRequest)
        case invalid(status: Int, message: String)
    }

    static let maxHeaderBytes = 32 * 1024
    static let maxBodyBytes = 8 * 1024 * 1024
    /// All that is read for one request: headers, body and the framing of a chunked body.
    static let maxRequestBytes = maxHeaderBytes + maxBodyBytes + 64 * 1024

    static func parse(_ buffer: Data) -> Outcome {
        guard buffer.count <= maxRequestBytes else { return .invalid(status: 413, message: "Request too large") }
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator) else {
            return buffer.count > maxHeaderBytes ? .invalid(status: 431, message: "Headers too large") : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes else { return .invalid(status: 431, message: "Headers too large") }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400, message: "Headers are not UTF-8")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid(status: 400, message: "Bad request line") }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400, message: "Bad header") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        var path = String(requestLine[1])
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        let bodyStart = end.upperBound
        let rest = buffer[bodyStart...]

        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch dechunk(Data(rest)) {
            case .incomplete: return .incomplete
            case .invalid: return .invalid(status: 400, message: "Bad chunked body")
            case .tooLarge: return .invalid(status: 413, message: "Body too large")
            case .complete(let data): body = data
            }
        } else if let lengthText = headers["content-length"] {
            guard let length = Int(lengthText), length >= 0 else { return .invalid(status: 400, message: "Bad Content-Length") }
            guard length <= maxBodyBytes else { return .invalid(status: 413, message: "Body too large") }
            guard rest.count >= length else { return .incomplete }
            body = Data(rest.prefix(length))
        } else {
            body = Data()
        }
        return .complete(HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, headers: headers, body: body))
    }

    private enum Chunked { case incomplete, invalid, tooLarge, complete(Data) }

    private static func dechunk(_ data: Data) -> Chunked {
        var body = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { return .incomplete }
            // A chunk size line is short: hex digits, maybe an extension.
            guard data.distance(from: index, to: lineEnd.lowerBound) <= 256,
                  let sizeText = String(data: data[index..<lineEnd.lowerBound], encoding: .ascii) else { return .invalid }
            let hex = sizeText.split(separator: ";", omittingEmptySubsequences: false).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            // More than 8 hex digits is beyond any allowed body; it is not even parsed (no overflow).
            guard !hex.isEmpty, hex.count <= 8, let size = Int(hex, radix: 16), size >= 0 else {
                return hex.count > 8 && hex.allSatisfy(\.isHexDigit) ? .tooLarge : .invalid
            }
            index = lineEnd.upperBound
            if size == 0 { return .complete(body) }
            guard size <= maxBodyBytes - body.count else { return .tooLarge }
            guard data.distance(from: index, to: data.endIndex) >= size + 2 else { return .incomplete }
            let chunkEnd = data.index(index, offsetBy: size)
            body.append(data[index..<chunkEnd])
            index = data.index(chunkEnd, offsetBy: 2)
        }
    }
}

/// Decides what an HTTP request gets: checks the path, the token and where the request comes from, then lets the
/// MCP core answer the message.
@MainActor
final class MCPHTTPHandler {
    let core: MCPServerCore
    private let token: () -> String

    init(core: MCPServerCore, token: @escaping () -> String) {
        self.core = core
        self.token = token
    }

    func respond(to request: HTTPRequest) async -> HTTPResponse {
        guard request.path == "/mcp" || request.path == "/mcp/" else { return .text(404, "Not found. The MCP endpoint is /mcp.") }
        // A web page must not reach the server through the browser (DNS rebinding): only local origins, or none.
        if let origin = request.header("origin"), !Self.isLocalOrigin(origin) { return .text(403, "Origin not allowed") }
        if let host = request.header("host"), !Self.isLocalHost(host) { return .text(403, "Host not allowed") }
        guard Self.isAuthorized(request.header("authorization"), token: token()) else {
            return .text(401, "A valid token is needed: Authorization: Bearer <token> (Porridge › Settings › MCP Server).",
                         headers: [("WWW-Authenticate", "Bearer realm=\"porridge\"")])
        }
        switch request.method {
        case "POST":
            if let type = request.header("content-type"), !type.lowercased().contains("json") {
                return .text(415, "Content-Type must be application/json")
            }
            guard let answer = await core.handle(request.body) else { return HTTPResponse(status: 202) }
            return .json(answer)
        case "DELETE":
            // No sessions are kept: there is nothing to end.
            return HTTPResponse(status: 204)
        default:
            return .text(405, "Use POST", headers: [("Allow", "POST, DELETE")])
        }
    }

    static func isAuthorized(_ header: String?, token: String) -> Bool {
        guard !token.isEmpty, let header else { return false }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        let given = Array(parts[1].trimmingCharacters(in: .whitespaces).utf8), expected = Array(token.utf8)
        guard given.count == expected.count else { return false }
        // Compared in full every time, so the time taken says nothing about the token.
        return zip(given, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func isLocalOrigin(_ origin: String) -> Bool {
        if origin == "null" { return false }
        guard let host = URL(string: origin)?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    static func isLocalHost(_ host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("[") { name = String(name.prefix { $0 != "]" }.dropFirst()) }
        else if let colon = name.lastIndex(of: ":") { name = String(name[..<colon]) }
        return ["localhost", "127.0.0.1", "::1"].contains(name)
    }
}

/// The listening socket: TCP on 127.0.0.1 only (never on the network), one request per connection.
final class MCPHTTPServer: @unchecked Sendable {
    enum State: Equatable {
        case starting
        case ready(port: Int)
        case failed(String)
        case stopped
    }

    private let queue = DispatchQueue(label: "de.letzgo.porridge.mcp")
    private var listener: NWListener?
    private let handler: MCPHTTPHandler
    private let onState: @MainActor (State) -> Void

    init(handler: MCPHTTPHandler, onState: @escaping @MainActor (State) -> Void) {
        self.handler = handler
        self.onState = onState
    }

    func start(port: Int) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            report(.failed("Invalid port \(port)"))
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.report(.ready(port: Int(listener.port?.rawValue ?? nwPort.rawValue)))
                case .failed(let error):
                    self?.report(.failed(Self.describe(error, port: port)))
                    listener.cancel()
                case .waiting(let error): self?.report(.failed(Self.describe(error, port: port)))
                case .cancelled: self?.report(.stopped)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            self.listener = listener
            report(.starting)
            listener.start(queue: queue)
        } catch {
            report(.failed(Self.describe(error, port: port)))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private static func describe(_ error: Error, port: Int) -> String {
        if case NWError.posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is used by another program."
        }
        return error.localizedDescription
    }

    private func report(_ state: State) {
        let onState = onState
        Task { @MainActor in onState(state) }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
        // A client that sends nothing is not waited for forever.
        queue.asyncAfter(deadline: .now() + 60) { [weak connection] in connection?.cancel() }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequestParser.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil { connection.cancel() } else { self.receive(connection, buffer: buffer) }
            case .invalid(let status, let message):
                self.send(.text(status, message), on: connection)
            case .complete(let request):
                let handler = self.handler
                Task { @MainActor in
                    let response = await handler.respond(to: request)
                    self.send(response, on: connection)
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
