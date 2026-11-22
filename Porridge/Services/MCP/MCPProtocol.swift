import Foundation

// The Model Context Protocol as far as Porridge speaks it: JSON-RPC 2.0 messages with `initialize`, `ping`,
// `tools/list` and `tools/call`. No resources, prompts or sampling; the server never sends requests of its own.
// The transport (HTTP on localhost, `MCPHTTP`) hands every message body to `MCPServerCore.handle`.

/// A JSON-RPC error: the standard codes and a message.
struct JSONRPCError: Error, Equatable {
    var code: Int
    var message: String

    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603

    static func parse(_ message: String = "Parse error") -> JSONRPCError { JSONRPCError(code: parseError, message: message) }
    static func invalid(_ message: String = "Invalid request") -> JSONRPCError { JSONRPCError(code: invalidRequest, message: message) }
    static func noMethod(_ method: String) -> JSONRPCError { JSONRPCError(code: methodNotFound, message: "Method not found: \(method)") }
    static func params(_ message: String) -> JSONRPCError { JSONRPCError(code: invalidParams, message: message) }
}

/// A message that could not be read, with its id when one could be read, so it can be answered.
struct JSONRPCFailure: Error, Equatable {
    var id: JSONValue
    var error: JSONRPCError
}

/// One incoming JSON-RPC message: a request (with an id, wants an answer), a notification (no id), or a response
/// to a request of ours (the server sends none, so it is ignored).
enum JSONRPCMessage: Equatable {
    case request(id: JSONValue, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response(id: JSONValue)

    /// Reads one message object. The error carries the id when one could be read, so it can be answered.
    static func parse(_ value: JSONValue) -> Result<JSONRPCMessage, JSONRPCFailure> {
        guard case .object(let object) = value else { return .failure(JSONRPCFailure(id: .null, error: .invalid())) }
        let id = object["id"]
        // An id must be a string or a number (null is allowed by JSON-RPC, but MCP forbids it).
        if let id {
            switch id {
            case .string, .int, .double: break
            default: return .failure(JSONRPCFailure(id: .null, error: .invalid("The id must be a string or a number")))
            }
        }
        guard object["jsonrpc"]?.stringValue == "2.0" else { return .failure(JSONRPCFailure(id: id ?? .null, error: .invalid("jsonrpc must be \"2.0\""))) }
        guard let method = object["method"] else {
            if let id, object["result"] != nil || object["error"] != nil { return .success(.response(id: id)) }
            return .failure(JSONRPCFailure(id: id ?? .null, error: .invalid("method is missing")))
        }
        guard let name = method.stringValue, !name.isEmpty else { return .failure(JSONRPCFailure(id: id ?? .null, error: .invalid("method must be a string"))) }
        let params = object["params"]
        if let params {
            switch params {
            case .object, .array: break
            default: return .failure(JSONRPCFailure(id: id ?? .null, error: .invalid("params must be an object or an array")))
            }
        }
        if let id { return .success(.request(id: id, method: name, params: params)) }
        return .success(.notification(method: name, params: params))
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSONValue, _ error: JSONRPCError) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(error.code), "message": .string(error.message)]]
    }
}

// MARK: - Tools

struct MCPToolDefinition {
    var name: String
    var title: String
    var description: String
    var inputSchema: JSONValue
    var readOnly: Bool
    var idempotent: Bool = true

    var json: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            // Hints for the client: nothing of Porridge's tools deletes, and they never reach out to the web.
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": false,
                "idempotentHint": .bool(idempotent),
                "openWorldHint": false,
            ],
        ]
    }
}

/// What a tool answers: text for the model, the same as structured JSON, and whether it went wrong.
struct MCPToolResult: Equatable {
    var text: String
    var structured: JSONValue?
    var isError = false

    static func json(_ value: JSONValue) -> MCPToolResult {
        MCPToolResult(text: value.text(pretty: true), structured: value.objectValue == nil ? ["result": value] : value)
    }

    static func failure(_ message: String) -> MCPToolResult {
        MCPToolResult(text: message, structured: nil, isError: true)
    }

    var json: JSONValue {
        var result: [String: JSONValue] = ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
        if let structured { result["structuredContent"] = structured }
        return .object(result)
    }
}

/// The tools a server offers; `MCPToolbox` is Porridge's.
@MainActor
protocol MCPToolProvider: AnyObject {
    /// The tools offered right now (write tools only while they are allowed).
    var tools: [MCPToolDefinition] { get }
    /// Runs a tool. Nil when there is no tool of that name.
    func call(_ name: String, arguments: [String: JSONValue]) async -> MCPToolResult?
}

// MARK: - Server

/// Answers MCP messages. Stateless: every message stands on its own, so several clients can use it at once.
@MainActor
final class MCPServerCore {
    /// The protocol versions understood, newest first. A client asking for another one is offered the newest.
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let serverName = "porridge"

    static let instructions = """
    Porridge is the user's private notes app. Its entries are notes, meetings (recordings with transcript and \
    summary), saved links, to-dos (notes with a done state and subtasks), images and files (scanned or shared \
    documents such as invoices, with their kind, date, sender and amount). Each entry is either in the Inbox or in \
    exactly one Bowl (a topic or project the user files entries into). Use `search` to find entries by words and \
    filters, `get_entry` to read one in full, `list_bowls`, `list_inbox` and `recent_entries` to look around. \
    Entry and bowl ids are UUIDs. Answer from what the tools return; the content is the user's own data.
    """

    let tools: MCPToolProvider
    let version: String

    init(tools: MCPToolProvider, version: String) {
        self.tools = tools
        self.version = version
    }

    /// Answers a message body: one message or a batch (an array). Nil when there is nothing to answer (only
    /// notifications or responses), else the answer to send back.
    func handle(_ body: Data) async -> Data? {
        let value: JSONValue
        do {
            value = try JSONValue.parse(body)
        } catch {
            return JSONRPCMessage.error(id: .null, .parse()).data()
        }
        if case .array(let batch) = value {
            guard !batch.isEmpty else { return JSONRPCMessage.error(id: .null, .invalid("Empty batch")).data() }
            var answers: [JSONValue] = []
            for message in batch {
                if let answer = await handle(message: message) { answers.append(answer) }
            }
            return answers.isEmpty ? nil : JSONValue.array(answers).data()
        }
        return await handle(message: value)?.data()
    }

    /// Answers one message; nil for a notification or a response.
    func handle(message: JSONValue) async -> JSONValue? {
        switch JSONRPCMessage.parse(message) {
        case .failure(let failure):
            return JSONRPCMessage.error(id: failure.id, failure.error)
        case .success(.notification), .success(.response):
            return nil
        case .success(.request(let id, let method, let params)):
            switch await respond(method: method, params: params) {
            case .success(let result): return JSONRPCMessage.result(id: id, result)
            case .failure(let error): return JSONRPCMessage.error(id: id, error)
            }
        }
    }

    private func respond(method: String, params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        switch method {
        case "initialize":
            let asked = params?["protocolVersion"]?.stringValue
            let version = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
            return .success([
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(Self.serverName), "title": "Porridge", "version": .string(self.version)],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            return .success([:])
        case "tools/list":
            return .success(["tools": .array(tools.tools.map(\.json))])
        case "tools/call":
            guard let name = params?["name"]?.stringValue else { return .failure(.params("The tool name is missing")) }
            let arguments: [String: JSONValue]
            switch params?["arguments"] {
            case nil, .null?: arguments = [:]
            case .object(let object)?: arguments = object
            default: return .failure(.params("arguments must be an object"))
            }
            guard let result = await tools.call(name, arguments: arguments) else { return .failure(.params("Unknown tool: \(name)")) }
            return .success(result.json)
        // Asked by some clients even though no capability says so: answered empty rather than with an error.
        case "resources/list":
            return .success(["resources": []])
        case "resources/templates/list":
            return .success(["resourceTemplates": []])
        case "prompts/list":
            return .success(["prompts": []])
        default:
            return .failure(.noMethod(method))
        }
    }
}
