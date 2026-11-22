import AppKit
import Observation

/// The local MCP server of the Mac app (Settings › MCP Server, off by default): Streamable HTTP on 127.0.0.1 with a
/// token, answered from the app's own store and index. Clients that only start programs (Claude Desktop) run the
/// app's binary with `--mcp` (`MCPBridge`), which passes their messages on to this server.
@MainActor
@Observable
final class MCPService {
    static let shared = MCPService()

    private(set) var state: MCPHTTPServer.State = .stopped

    @ObservationIgnored private var server: MCPHTTPServer?
    @ObservationIgnored private var runningPort: Int?
    /// Counts the servers started, so a late message of a stopped one changes nothing.
    @ObservationIgnored private var generation = 0

    private init() {}

    var isEnabled: Bool { MCPSettings.isEnabled }

    /// Starts or stops the server as the settings say. Called at launch and whenever the switch changes.
    func applySettings() {
        if MCPSettings.isEnabled {
            if server == nil || runningPort != MCPSettings.port { start() }
        } else {
            stop()
        }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: MCPSettings.enabledKey)
        if on { _ = Self.token }
        applySettings()
    }

    private func start() {
        stop()
        let library = Library.shared
        let toolbox = MCPToolbox(
            context: library.context,
            permissions: { MCPSettings.permissions },
            passages: { notes in
                // Whatever came in since the last look is read into the index first (cheap when nothing changed).
                await NoteIndex.shared.refresh(notes)
                return NoteIndex.shared.chunks
            },
            queryVector: { await TextEmbedder.shared.vector(for: $0) }
        )
        let core = MCPServerCore(tools: toolbox, version: Self.appVersion)
        let handler = MCPHTTPHandler(core: core, token: { Self.token })
        generation += 1
        let current = generation
        let server = MCPHTTPServer(handler: handler) { [weak self] state in
            guard let self, self.generation == current, self.server != nil else { return }
            self.state = state
        }
        self.server = server
        runningPort = MCPSettings.port
        server.start(port: MCPSettings.port)
    }

    private func stop() {
        generation += 1
        server?.stop()
        server = nil
        runningPort = nil
        state = .stopped
    }

    // MARK: Token

    /// The secret every request carries; made the first time it is needed. The bridge reads it from the same
    /// defaults, so Claude Desktop needs no token in its configuration.
    static var token: String {
        if let token = UserDefaults.standard.string(forKey: MCPSettings.tokenKey), token.count >= 32 { return token }
        let token = newToken()
        UserDefaults.standard.set(token, forKey: MCPSettings.tokenKey)
        return token
    }

    /// A new token: clients configured with the old one (by URL and header) have to be given the new one.
    static func resetToken() {
        UserDefaults.standard.set(newToken(), forKey: MCPSettings.tokenKey)
    }

    private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Configuration for clients

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    /// The program clients start: this app's binary, which acts as the bridge with `--mcp`.
    static var executablePath: String {
        Bundle.main.executablePath ?? "/Applications/Porridge.app/Contents/MacOS/Porridge"
    }

    static var endpoint: String { "http://127.0.0.1:\(MCPSettings.port)/mcp" }

    /// For `claude_desktop_config.json` (Claude Desktop › Settings › Developer › Edit Config).
    static var desktopConfig: String {
        let path = JSONValue.string(executablePath).text()
        return """
        {
          "mcpServers": {
            "porridge": {
              "command": \(path),
              "args": ["--mcp"]
            }
          }
        }
        """
    }

    /// For Claude Code: the same bridge, added for every project of the user.
    static var claudeCodeCommand: String {
        "claude mcp add --scope user porridge -- \(shellQuoted(executablePath)) --mcp"
    }

    /// For clients that speak Streamable HTTP themselves.
    static func httpCommand(token: String) -> String {
        "claude mcp add --scope user --transport http porridge \(endpoint) --header \"Authorization: Bearer \(token)\""
    }

    private static func shellQuoted(_ text: String) -> String {
        text.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) } ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
