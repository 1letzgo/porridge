import AppKit
import Foundation

/// `Porridge --mcp`: the stdio side of the MCP server, for clients that start a program and talk to it over stdin
/// and stdout (Claude Desktop, Claude Code). It runs the app's own binary without any window and passes each
/// message line on to the running app's server on 127.0.0.1 (`MCPService`), with the token from the app's
/// settings, which it shares (same app, same sandbox container). The answer goes back as one line on stdout.
/// When the app is not running it is started in the background first.
enum MCPBridge {
    static let argument = "--mcp"

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let answer = forward(Data(trimmed.utf8)) {
                FileHandle.standardOutput.write(answer + Data("\n".utf8))
            }
        }
        exit(0)
    }

    /// Passes one message on; the answer (one line of JSON), or nil when there is none (a notification).
    static func forward(_ message: Data) -> Data? {
        guard UserDefaults.standard.bool(forKey: MCPSettings.enabledKey),
              let token = UserDefaults.standard.string(forKey: MCPSettings.tokenKey), !token.isEmpty else {
            return errorAnswer(to: message, "Porridge's MCP server is off. Turn it on in Porridge › Settings › MCP Server.")
        }
        var outcome = post(message, token: token)
        if case .unreachable = outcome {
            launchApp()
            // The app opens its store and starts the server: give it a moment.
            for _ in 0..<40 {
                Thread.sleep(forTimeInterval: 0.5)
                outcome = post(message, token: token)
                if case .unreachable = outcome { continue }
                break
            }
        }
        switch outcome {
        case .answer(let data): return data
        case .accepted: return nil
        case .rejected(let status, let text):
            if status == 401 {
                return errorAnswer(to: message, "Porridge refused the token. Turn the MCP server off and on again in Porridge › Settings › MCP Server.")
            }
            return errorAnswer(to: message, "Porridge answered \(status): \(text)")
        case .unreachable:
            return errorAnswer(to: message, "Porridge is not running or its MCP server is not ready. Open Porridge and check Settings › MCP Server.")
        }
    }

    private enum Outcome {
        case answer(Data)
        case accepted
        case rejected(Int, String)
        case unreachable
    }

    private static func post(_ body: Data, token: String) -> Outcome {
        let port = MCPSettings.port
        guard let url = URL(string: "http://127.0.0.1:\(port)/mcp") else { return .unreachable }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let semaphore = DispatchSemaphore(value: 0)
        var outcome = Outcome.unreachable
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            guard error == nil, let http = response as? HTTPURLResponse else { return }
            switch http.statusCode {
            case 200: outcome = .answer(oneLine(data ?? Data()))
            case 202, 204: outcome = .accepted
            default: outcome = .rejected(http.statusCode, String(decoding: data ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        task.resume()
        semaphore.wait()
        return outcome
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 300
        return URLSession(configuration: configuration)
    }()

    /// The server writes compact JSON; should a line break slip in, it would split the message on stdout.
    private static func oneLine(_ data: Data) -> Data {
        guard data.contains(10) || data.contains(13) else { return data }
        return (try? JSONValue.parse(data).data()) ?? data
    }

    /// Opens the app in the background (no window comes to the front). This bridge is the app's own binary, so
    /// Launch Services could take it for the running app and open nothing: whether the app runs is decided here,
    /// by its bundle id without this process, and when it does not, a new instance is asked for explicitly.
    private static func launchApp() {
        let me = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains {
            $0.processIdentifier != me && !$0.isTerminated
        }
        // It runs: its server is off or still starting; a second app is never opened.
        guard !running else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 10)
    }

    /// A JSON-RPC error for every request in `message`; nil when it holds only notifications.
    static func errorAnswer(to message: Data, _ text: String) -> Data? {
        let value = (try? JSONValue.parse(message)) ?? .null
        let messages = value.arrayValue ?? [value]
        let errors: [JSONValue] = messages.compactMap { item in
            guard let id = item["id"], !id.isNull else { return item.objectValue == nil ? JSONRPCMessage.error(id: .null, .parse()) : nil }
            return JSONRPCMessage.error(id: id, JSONRPCError(code: JSONRPCError.internalError, message: text))
        }
        if errors.isEmpty { return nil }
        return value.arrayValue == nil ? errors[0].data() : JSONValue.array(errors).data()
    }
}
