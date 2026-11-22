import AppKit

// `Porridge --mcp`: started by an MCP client (Claude Desktop, Claude Code) as its stdio server. No window, no Dock
// icon: the messages are passed on to the running app (`MCPBridge`), and the process ends with stdin.
if CommandLine.arguments.dropFirst().contains(MCPBridge.argument) {
    MCPBridge.run()
}

// The app starts here: an AppKit application with its delegate (no SwiftUI scene).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
