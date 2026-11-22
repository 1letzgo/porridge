import Foundation
import SwiftData
import XCTest
@testable import Porridge

/// The local MCP server: JSON-RPC messages, the MCP methods, the tools (search, reading, the two allowed changes),
/// and the HTTP side (parsing, token, origin).
@MainActor
final class MCPTests: XCTestCase {
    private var context: ModelContext!
    private var permissions = MCPPermissions()
    private var toolbox: MCPToolbox!
    private var core: MCPServerCore!
    private var travel: NoteFolder!
    private var work: NoteFolder!

    override func setUp() async throws {
        context = try TestStore.context()
        permissions = MCPPermissions()
        toolbox = MCPToolbox(context: context, permissions: { [unowned self] in self.permissions })
        core = MCPServerCore(tools: toolbox, version: "1.0 (test)")
        travel = NoteFolder(name: "Travel")
        work = NoteFolder(name: "Work")
        context.insert(travel)
        context.insert(work)
        try context.save()
    }

    // MARK: JSON-RPC

    func testMessagesAreReadAsRequestsNotificationsAndResponses() throws {
        let request = try JSONValue.parse(Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{}}"#.utf8))
        XCTAssertEqual(try JSONRPCMessage.parse(request).get(), .request(id: 7, method: "tools/list", params: [:]))
        let notification = try JSONValue.parse(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        XCTAssertEqual(try JSONRPCMessage.parse(notification).get(), .notification(method: "notifications/initialized", params: nil))
        let response = try JSONValue.parse(Data(#"{"jsonrpc":"2.0","id":"a","result":{}}"#.utf8))
        XCTAssertEqual(try JSONRPCMessage.parse(response).get(), .response(id: "a"))

        for bad in [#"{"id":1,"method":"ping"}"#, #"{"jsonrpc":"1.0","id":1,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":1}"#,
                    #"{"jsonrpc":"2.0","id":{"x":1},"method":"ping"}"#, #"{"jsonrpc":"2.0","id":1,"method":"ping","params":3}"#, "[1]"] {
            let value = try JSONValue.parse(Data(bad.utf8))
            if case .array(let items) = value {
                guard case .failure = JSONRPCMessage.parse(items[0]) else { return XCTFail(bad) }
                continue
            }
            guard case .failure(let failure) = JSONRPCMessage.parse(value) else { return XCTFail("accepted \(bad)") }
            XCTAssertEqual(failure.error.code, JSONRPCError.invalidRequest, bad)
        }
    }

    func testIdsKeepTheirTypeAndBrokenJSONIsAParseError() async throws {
        let answer = try await send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        XCTAssertEqual(answer, ["jsonrpc": "2.0", "id": 1, "result": [:]])
        XCTAssertTrue(String(decoding: answer.data(), as: UTF8.self).contains(#""id":1,"#), "1, not 1.0")
        let text = try await send(#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#)
        XCTAssertEqual(text["id"], "abc")

        let broken = try await send("{not json")
        XCTAssertEqual(broken["error"]?["code"], .int(JSONRPCError.parseError))
        XCTAssertEqual(broken["id"], .null)

        let unknown = try await send(#"{"jsonrpc":"2.0","id":2,"method":"sampling/createMessage"}"#)
        XCTAssertEqual(unknown["error"]?["code"], .int(JSONRPCError.methodNotFound))
    }

    func testNotificationsAreNotAnsweredAndBatchesAre() async throws {
        let none = await core.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        XCTAssertNil(none)
        let v1 = await core.handle(Data(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"ping"}]"#.utf8))
        let batch = try XCTUnwrap(v1)
        XCTAssertEqual(try JSONValue.parse(batch).arrayValue?.compactMap { $0["id"]?.intValue }, [1, 2])
    }

    func testInitializeNegotiatesTheVersionAndOffersTools() async throws {
        let answer = try await send(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        let result = try XCTUnwrap(answer["result"])
        XCTAssertEqual(result["protocolVersion"], "2025-03-26")
        XCTAssertNotNil(result["capabilities"]?["tools"])
        XCTAssertEqual(result["serverInfo"]?["name"], "porridge")
        XCTAssertEqual(result["serverInfo"]?["version"], "1.0 (test)")
        let future = try await send(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        XCTAssertEqual(future["result"]?["protocolVersion"], .string(MCPServerCore.protocolVersions[0]))
    }

    // MARK: Tools

    func testWriteToolsAreOnlyListedAndCallableWhenAllowed() async throws {
        let v2 = try await toolNames()
        XCTAssertEqual(v2, ["search", "get_entry", "list_bowls", "list_inbox", "recent_entries"])
        let refused = try await call("create_note", ["text": "Hello"])
        XCTAssertEqual(refused["isError"], true)
        XCTAssertTrue(try XCTUnwrap(refused["content"]?.arrayValue?.first?["text"]?.stringValue).contains("Allow changes"))
        XCTAssertTrue(try context.fetch(FetchDescriptor<Note>()).isEmpty, "nothing was created")

        permissions.createNote = true
        let v3 = try await toolNames()
        XCTAssertEqual(v3, ["search", "get_entry", "list_bowls", "list_inbox", "recent_entries", "create_note"])
        permissions.moveToBowl = true
        let v4 = try await toolNames().contains("move_to_bowl")
        XCTAssertTrue(v4)
        let v5 = try await toolNames().contains { $0.contains("delete") }
        XCTAssertFalse(v5, "there is no delete tool")

        let unknown = try await send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"delete_entry","arguments":{}}}"#)
        XCTAssertEqual(unknown["error"]?["code"], .int(JSONRPCError.invalidParams))
    }

    func testEveryToolHasAnObjectSchemaAndHints() async throws {
        permissions = MCPPermissions(createNote: true, moveToBowl: true)
        let list = try await send(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        for tool in try XCTUnwrap(list["result"]?["tools"]?.arrayValue) {
            XCTAssertEqual(tool["inputSchema"]?["type"], "object")
            XCTAssertEqual(tool["annotations"]?["destructiveHint"], false)
            let name = try XCTUnwrap(tool["name"]?.stringValue)
            let readOnly = !["create_note", "move_to_bowl"].contains(name)
            XCTAssertEqual(tool["annotations"]?["readOnlyHint"], .bool(readOnly), name)
        }
    }

    func testCreateNoteLandsInTheInboxOrTheNamedBowl() async throws {
        permissions.createNote = true
        let inbox = try await structured("create_note", ["text": "Buy #coffee beans", "title": "Shopping"])
        let id = try XCTUnwrap(inbox["entry"]?["id"]?.stringValue)
        XCTAssertEqual(inbox["entry"]?["in_inbox"], true)
        XCTAssertEqual(inbox["entry"]?["tags"], ["coffee"])
        let note = try XCTUnwrap(try context.fetch(FetchDescriptor<Note>()).first { $0.id.uuidString == id })
        XCTAssertEqual(note.title, "Shopping")
        XCTAssertEqual(note.source, .note)
        XCTAssertTrue(note.isInInbox)

        let filed = try await structured("create_note", ["text": "Pack the passport", "bowl": "travel"])
        XCTAssertEqual(filed["entry"]?["bowl"]?["name"], "Travel")
        XCTAssertEqual(filed["entry"]?["bowl"]?["id"], .string(travel.id.uuidString))

        let empty = try await call("create_note", ["text": "  "])
        XCTAssertEqual(empty["isError"], true)
        let nowhere = try await call("create_note", ["text": "x", "bowl": "Garden"])
        XCTAssertEqual(nowhere["isError"], true)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Note>()).count, 2)
    }

    func testMoveToBowlKeepsOneBowlAndCanGoBackToTheInbox() async throws {
        permissions.moveToBowl = true
        let note = Note()
        note.text = "Hotel booking"
        note.projectIDs = [Projects.key(work)]
        context.insert(note)
        try context.save()

        let moved = try await structured("move_to_bowl", ["id": .string(note.id.uuidString), "bowl": .string(travel.id.uuidString)])
        XCTAssertEqual(moved["entry"]?["bowl"]?["name"], "Travel")
        XCTAssertEqual(note.projectIDs, [Projects.key(travel)], "in one bowl at most")

        _ = try await structured("move_to_bowl", ["id": .string(note.id.uuidString), "to_inbox": true])
        XCTAssertTrue(note.isInInbox)

        let both = try await call("move_to_bowl", ["id": .string(note.id.uuidString), "bowl": "Work", "to_inbox": true])
        XCTAssertEqual(both["isError"], true)
        let missing = try await call("move_to_bowl", ["id": .string(UUID().uuidString), "bowl": "Work"])
        XCTAssertEqual(missing["isError"], true)
        travel.archivedAt = Date()
        let archived = try await call("move_to_bowl", ["id": .string(note.id.uuidString), "bowl": "Travel"])
        XCTAssertEqual(archived["isError"], true)
        XCTAssertTrue(note.isInInbox)
    }

    func testSearchFindsByWordsAndFilters() async throws {
        let goa = add("Trip to Goa", text: "Flights booked, beach hotel in Palolem #holiday", bowl: travel, created: "2026-03-01")
        let berlin = add("Berlin weekend", text: "Museum island and a hotel near the river", bowl: travel, created: "2026-05-10")
        let review = add("Quarterly review", text: "Budget and hiring plan", bowl: work, created: "2026-06-01")
        let loose = add("Hotel ideas", text: "Places to stay some day", bowl: nil, created: "2026-07-01")
        let invoice = add("Telekom", text: "", bowl: nil, created: "2026-08-01")
        invoice.source = .share
        invoice.attachments = [Attachment(fileName: "t.pdf", name: "Telekom.pdf", kindRaw: "pdf")]
        invoice.documentInfo = DocumentInfo(kind: .invoice, day: "2026-07-28", correspondent: "Telekom", amount: "39.95 EUR")
        try context.save()

        let hotels = try await ids("search", ["query": "hotel"])
        XCTAssertEqual(Set(hotels), [goa, berlin, loose].map(\.id.uuidString).asSet)
        XCTAssertFalse(hotels.contains(review.id.uuidString))

        let inTravel = try await ids("search", ["query": "hotel", "bowl": "Travel"])
        XCTAssertEqual(Set(inTravel), [goa, berlin].map(\.id.uuidString).asSet)
        let v6 = try await ids("search", ["query": "hotel", "inbox": true])
        XCTAssertEqual(v6, [loose.id.uuidString])
        let v7 = try await ids("search", ["tag": "#Holiday"])
        XCTAssertEqual(v7, [goa.id.uuidString])
        let v8 = try await ids("search", ["bowl": "Travel", "from": "2026-04-01"])
        XCTAssertEqual(v8, [berlin.id.uuidString])
        let v9 = try await ids("search", ["bowl": "Travel", "to": "2026-03-01"])
        XCTAssertEqual(v9, [goa.id.uuidString], "to is inclusive")
        let v10 = try await ids("search", ["document_kind": "invoice"])
        XCTAssertEqual(v10, [invoice.id.uuidString])
        let v11 = try await ids("search", ["kind": "file"])
        XCTAssertEqual(v11, [invoice.id.uuidString])
        // Without words, newest (by the document's date) first.
        let v12 = try await ids("search", ["limit": 2])
        XCTAssertEqual(v12, [invoice.id.uuidString, loose.id.uuidString])

        let result = try await structured("search", ["query": "Palolem"])
        XCTAssertEqual(result["total"], 1)
        XCTAssertTrue(result["results"]?.arrayValue?.first?["match"]?.stringValue?.contains("Palolem") ?? false)

        let v13 = try await call("search", ["kind": "spaceship"])["isError"]
        XCTAssertEqual(v13, true)
        let v14 = try await call("search", ["from": "yesterday"])["isError"]
        XCTAssertEqual(v14, true)
        let v15 = try await call("search", ["bowl": "Garden"])["isError"]
        XCTAssertEqual(v15, true)
    }

    func testGetEntryGivesEverythingAndListsGiveTheInboxAndBowls() async throws {
        let meeting = add("Planning", text: "My notes", bowl: work, created: "2026-09-01")
        meeting.summary = "We decided to ship."
        meeting.speakers = [Speaker(id: "s1", name: "Anna", colorIndex: 0)]
        meeting.segments = [TranscriptSegment(speakerId: "s1", start: 0, end: 4, text: "Let's ship it.")]
        let todo = add("Pack", text: "- [x] Passport\n- [ ] Charger", bowl: nil, created: "2026-09-02")
        todo.todoStateRaw = TodoState.open.rawValue
        let trashed = add("Gone", text: "old", bowl: nil, created: "2026-09-03")
        trashed.deletedAt = Date()
        try context.save()

        let entry = try await structured("get_entry", ["id": .string(meeting.id.uuidString)])
        XCTAssertEqual(entry["kind"], "meeting")
        XCTAssertEqual(entry["summary"], "We decided to ship.")
        XCTAssertTrue(entry["transcript"]?.stringValue?.contains("Anna: Let's ship it.") ?? false)
        XCTAssertEqual(entry["bowl"]?["name"], "Work")
        XCTAssertEqual(entry["text"], "My notes")

        let task = try await structured("get_entry", ["id": .string(todo.id.uuidString)])
        XCTAssertEqual(task["todo"]?["state"], "open")
        XCTAssertEqual(task["todo"]?["subtasks"]?.arrayValue?.count, 2)

        let v16 = try await call("get_entry", ["id": .string(trashed.id.uuidString)])["isError"]
        XCTAssertEqual(v16, true, "the trash is not readable")
        let v17 = try await call("get_entry", ["id": "nope"])["isError"]
        XCTAssertEqual(v17, true)

        let long = try await structured("get_entry", ["id": .string(meeting.id.uuidString), "max_length": 500])
        XCTAssertNil(long["truncated"])

        let inbox = try await structured("list_inbox", [:])
        XCTAssertEqual(inbox["entries"]?.arrayValue?.compactMap { $0["id"]?.stringValue }, [todo.id.uuidString])

        let bowls = try await structured("list_bowls", [:])
        let list = try XCTUnwrap(bowls["bowls"]?.arrayValue)
        XCTAssertEqual(list.compactMap { $0["name"]?.stringValue }, ["Travel", "Work"])
        XCTAssertEqual(list.first { $0["name"] == "Work" }?["entries"], 1)
        XCTAssertEqual(bowls["inbox_entries"], 1)
        travel.archivedAt = Date()
        let v18 = try await structured("list_bowls", [:])["bowls"]?.arrayValue?.count
        XCTAssertEqual(v18, 1)
        let v19 = try await structured("list_bowls", ["include_archived": true])["bowls"]?.arrayValue?.count
        XCTAssertEqual(v19, 2)

        let recent = try await ids("recent_entries", ["limit": 1])
        XCTAssertEqual(recent, [todo.id.uuidString])
        let v20 = try await ids("recent_entries", ["kind": "meeting"])
        XCTAssertEqual(v20, [meeting.id.uuidString])
    }

    func testTwoBowlsOfOneNameMustBeNamedById() throws {
        context.insert(NoteFolder(name: "Travel"))
        try context.save()
        XCTAssertThrowsError(try toolbox.resolveBowl("travel"))
        XCTAssertEqual(try toolbox.resolveBowl(travel.id.uuidString).id, travel.id)
    }

    // MARK: HTTP

    func testHTTPRequestsAreParsedWhenComplete() {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let raw = "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1:52830\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        guard case .complete(let request) = HTTPRequestParser.parse(Data(raw.utf8)) else { return XCTFail() }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertEqual(request.header("content-type"), "application/json")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), body)

        XCTAssertEqual(HTTPRequestParser.parse(Data(raw.utf8.dropLast(3))), .incomplete)
        XCTAssertEqual(HTTPRequestParser.parse(Data("POST /mcp HTTP/1.1\r\nHost: x".utf8)), .incomplete)
        guard case .invalid(400, _) = HTTPRequestParser.parse(Data("NONSENSE\r\n\r\n".utf8)) else { return XCTFail() }
        guard case .invalid(413, _) = HTTPRequestParser.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n".utf8)) else { return XCTFail() }

        let chunked = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
        guard case .complete(let dechunked) = HTTPRequestParser.parse(Data(chunked.utf8)) else { return XCTFail() }
        XCTAssertEqual(String(decoding: dechunked.body, as: UTF8.self), "hello world")

        // A chunk size near Int.max must not overflow (it used to crash the app before any token was checked).
        let huge = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n7fffffffffffffff\r\nx\r\n"
        guard case .invalid(413, _) = HTTPRequestParser.parse(Data(huge.utf8)) else { return XCTFail("huge chunk") }
        let long = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" + String(repeating: "0", count: 300) + "1\r\nx\r\n0\r\n\r\n"
        guard case .invalid = HTTPRequestParser.parse(Data(long.utf8)) else { return XCTFail("long size line") }
        guard case .invalid(400, _) = HTTPRequestParser.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n".utf8)) else {
            return XCTFail("not hex")
        }
        let tooMuch = Data(count: HTTPRequestParser.maxRequestBytes + 1)
        guard case .invalid(413, _) = HTTPRequestParser.parse(tooMuch) else { return XCTFail("buffer cap") }
    }

    func testTheHTTPHandlerChecksTokenOriginAndMethod() async throws {
        let handler = MCPHTTPHandler(core: core, token: { "secret-token" })
        let ping = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        func request(_ method: String = "POST", path: String = "/mcp", headers: [String: String] = ["authorization": "Bearer secret-token"], body: Data = ping) -> HTTPRequest {
            HTTPRequest(method: method, path: path, headers: headers, body: body)
        }
        let ok = await handler.respond(to: request())
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(try JSONValue.parse(ok.body)["id"], 1)

        let v21 = await handler.respond(to: request(headers: [:])).status
        XCTAssertEqual(v21, 401)
        let v22 = await handler.respond(to: request(headers: ["authorization": "Bearer wrong-token!"])).status
        XCTAssertEqual(v22, 401)
        let v23 = await handler.respond(to: request(headers: ["authorization": "Bearer secret-token", "origin": "https://evil.example"])).status
        XCTAssertEqual(v23, 403)
        let v24 = await handler.respond(to: request(headers: ["authorization": "Bearer secret-token", "host": "evil.example:52830"])).status
        XCTAssertEqual(v24, 403)
        let v25 = await handler.respond(to: request(headers: ["authorization": "Bearer secret-token", "origin": "http://localhost:3000", "host": "localhost:52830"])).status
        XCTAssertEqual(v25, 200)
        let v26 = await handler.respond(to: request("GET")).status
        XCTAssertEqual(v26, 405)
        let v27 = await handler.respond(to: request(path: "/other")).status
        XCTAssertEqual(v27, 404)
        let notification = await handler.respond(to: request(body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)))
        XCTAssertEqual(notification.status, 202)
        XCTAssertTrue(notification.body.isEmpty)

        let wire = String(decoding: ok.serialized, as: UTF8.self)
        XCTAssertTrue(wire.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(wire.contains("Content-Length: \(ok.body.count)\r\n"))
        XCTAssertFalse(MCPHTTPHandler.isAuthorized("Bearer x", token: ""), "no token, no access")
    }

    /// The whole way over a real socket on 127.0.0.1: initialize, then the tool list.
    func testTheServerAnswersOverLoopback() async throws {
        let handler = MCPHTTPHandler(core: core, token: { "loop-token" })
        let ready = expectation(description: "listening")
        var port = 0
        let server = MCPHTTPServer(handler: handler) { state in
            if case .ready(let p) = state, port == 0 { port = p; ready.fulfill() }
        }
        server.start(port: Int.random(in: 53_000...59_000))
        await fulfillment(of: [ready], timeout: 5)
        defer { server.stop() }

        func post(_ body: String, token: String = "loop-token") async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
        let (status, data) = try await post(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(try JSONValue.parse(data)["result"]?["serverInfo"]?["name"], "porridge")
        let (listStatus, list) = try await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        XCTAssertEqual(listStatus, 200)
        XCTAssertEqual(try JSONValue.parse(list)["result"]?["tools"]?.arrayValue?.count, 5)
        let (refused, _) = try await post(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#, token: "wrong")
        XCTAssertEqual(refused, 401)
    }

    // MARK: Helpers

    private func send(_ text: String) async throws -> JSONValue {
        let v28 = await core.handle(Data(text.utf8))
        let data = try XCTUnwrap(v28)
        return try JSONValue.parse(data)
    }

    private func toolNames() async throws -> [String] {
        let list = try await send(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        return try XCTUnwrap(list["result"]?["tools"]?.arrayValue).compactMap { $0["name"]?.stringValue }
    }

    /// The result object of `tools/call` (content, isError, structuredContent).
    private func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        let message: JSONValue = ["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": ["name": .string(name), "arguments": .object(arguments)]]
        let v29 = await core.handle(message.data())
        let data = try XCTUnwrap(v29)
        let answer = try JSONValue.parse(data)
        return try XCTUnwrap(answer["result"], "\(answer)")
    }

    private func structured(_ name: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        let result = try await call(name, arguments)
        XCTAssertEqual(result["isError"], false, "\(result)")
        // The text is the same JSON for clients that read only text.
        let text = try XCTUnwrap(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        XCTAssertEqual(try JSONValue.parse(Data(text.utf8)), result["structuredContent"])
        return try XCTUnwrap(result["structuredContent"])
    }

    private func ids(_ name: String, _ arguments: [String: JSONValue]) async throws -> [String] {
        let result = try await structured(name, arguments)
        let list = result["results"]?.arrayValue ?? result["entries"]?.arrayValue ?? []
        return list.compactMap { $0["id"]?.stringValue }
    }

    @discardableResult
    private func add(_ title: String, text: String, bowl: NoteFolder?, created: String) -> Note {
        let note = Note()
        note.title = title
        note.text = text
        note.source = .note
        note.createdAt = DocumentInfo.date(fromDay: created)!
        note.updatedAt = note.createdAt
        if let bowl { note.projectIDs = [Projects.key(bowl)] }
        context.insert(note)
        return note
    }
}

private extension Array where Element: Hashable {
    var asSet: Set<Element> { Set(self) }
}
