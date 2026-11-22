import AppKit

/// MCP Server: lets Claude Desktop, Claude Code and other MCP clients on this Mac search and read the notes
/// (`MCPService`). Off by default; each change a client may make is allowed on its own. The configuration for the
/// clients is copied from here.
final class MCPSettingsPane: SettingsPane {
    private lazy var enabled = SettingsCheckbox("Enable MCP Server") { [weak self] on in
        MCPService.shared.setEnabled(on)
        self?.render()
    }
    private let status = NSTextField.label()
    private lazy var allowCreate = SettingsCheckbox("Create notes") {
        UserDefaults.standard.set($0, forKey: MCPSettings.allowCreateKey)
    }
    private lazy var allowMove = SettingsCheckbox("Move entries to bowls") {
        UserDefaults.standard.set($0, forKey: MCPSettings.allowMoveKey)
    }
    private let desktopSnippet = MCPSettingsPane.snippetLabel()
    private let codeSnippet = MCPSettingsPane.snippetLabel()
    private let httpSnippet = MCPSettingsPane.snippetLabel()

    override func build() {
        form.row("", enabled)
        form.row("Status", status)
        form.note("Lets Claude Desktop, Claude Code and other MCP clients on this Mac search and read your notes. The server only listens on this Mac. What a client reads goes to its AI model.")
        form.separator()

        form.row("Allow changes", allowCreate)
        form.row("", allowMove)
        form.note("New notes land in the Inbox or in the bowl the client names. Nothing can be deleted.")
        form.separator()

        form.row("Claude Desktop", NSButton.push("Copy Configuration") { MCPService.copy(MCPService.desktopConfig) })
        form.row("", desktopSnippet)
        form.note("In Claude Desktop, open Settings › Developer › Edit Config, add this to claude_desktop_config.json and restart Claude Desktop.")
        form.row("Claude Code", NSButton.push("Copy Command") { MCPService.copy(MCPService.claudeCodeCommand) })
        form.row("", codeSnippet)
        form.note("Run it once in Terminal.")
        form.row("Other Clients", NSStackView.horizontal([
            NSButton.push("Copy URL and Token") { MCPService.copy(MCPService.httpCommand(token: MCPService.token)) },
            NSButton.push("New Token") { [weak self] in self?.resetToken() },
        ], spacing: 8))
        form.row("", httpSnippet)
        form.note("For clients that speak Streamable HTTP. Every request needs the token.")
    }

    override func render() {
        let on = MCPSettings.isEnabled
        enabled.isOn = on
        allowCreate.isOn = UserDefaults.standard.bool(forKey: MCPSettings.allowCreateKey)
        allowMove.isOn = UserDefaults.standard.bool(forKey: MCPSettings.allowMoveKey)
        switch on ? MCPService.shared.state : .stopped {
        case .stopped:
            status.stringValue = on ? "Starting…" : "Off"
            status.textColor = .secondaryLabelColor
        case .starting:
            status.stringValue = "Starting…"
            status.textColor = .secondaryLabelColor
        case .ready(let port):
            status.stringValue = "Running on 127.0.0.1:\(port)"
            status.textColor = .labelColor
        case .failed(let message):
            status.stringValue = "Not running: \(message)"
            status.textColor = .brandDangerText
        }
        status.toolTip = status.stringValue
        desktopSnippet.stringValue = MCPService.desktopConfig
        codeSnippet.stringValue = MCPService.claudeCodeCommand
        httpSnippet.stringValue = "\(MCPService.endpoint)\nAuthorization: Bearer ••••••••"
        [allowCreate, allowMove].forEach { $0.isEnabled = on }
    }

    private func resetToken() {
        Alerts.confirm(
            "Make a New Token?",
            message: "Clients set up with the URL and token stop working until they get the new one. Claude Desktop and Claude Code set up with the command above keep working.",
            action: "New Token", isDestructive: false, style: .warning, in: view.window
        ) { [weak self] in
            MCPService.resetToken()
            self?.render()
        }
    }

    private static func snippetLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.isSelectable = true
        label.preferredMaxLayoutWidth = SettingsMetrics.controlWidth
        return label
    }
}
