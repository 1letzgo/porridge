#if DEBUG
import AppKit

/// Lets a developer drive the app from the command line in a debug build, for checking the interface without
/// clicking: with PORRIDGE_DEBUG_DRIVER set, commands written to `commandFile` are run. Not part of release builds.
///
/// Commands: `page inbox|chat|archive|trash|search`, `bucket <name>`, `select <row>`, `menu <Top>/<Item>[/<Sub>]`,
/// `search <text>`, `dump`, `key <window title>` (orders a window front), `title <text>` / `body <text>` (types
/// into the open note), `settings <tab>`.
@MainActor
enum DebugDriver {
    /// The file the commands are read from (one per line), and the file answers go to.
    static let commandFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("porridge-debug-commands")
    static let outputFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("porridge-debug-output")
    private static var timer: Timer?

    static func start() {
        guard ProcessInfo.processInfo.environment["PORRIDGE_DEBUG_DRIVER"] != nil else { return }
        try? FileManager.default.removeItem(at: commandFile)
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let text = try? String(contentsOf: commandFile, encoding: .utf8), !text.isEmpty else { return }
                try? FileManager.default.removeItem(at: commandFile)
                for line in text.split(separator: "\n") { run(String(line)) }
            }
        }
    }

    static func log(_ text: String) {
        let line = text + "\n"
        if let handle = try? FileHandle(forWritingTo: outputFile) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: outputFile, atomically: true, encoding: .utf8)
        }
    }

    static func run(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        let controller = MainWindowController.frontIfAny ?? MainWindowController.front
        let state = controller.state
        let library = Library.shared
        switch parts.first ?? "" {
        case "page":
            switch argument {
            case "chat": state.page = .chat
            case "archive": state.page = .archive
            case "trash": state.page = .trash
            case "search": state.page = .search
            default: state.page = .inbox
            }
        case "bucket":
            if let project = library.projects.first(where: { $0.name == argument }) { state.page = .project(project.id) }
        case "select":
            let built = NoteListContent.build(for: state, library: library)
            let ids = built.sections.flatMap(\.1).compactMap { item -> UUID? in
                if case .note(let id) = item { return id }
                return nil
            }
            if let index = Int(argument), index < ids.count { state.selection = [ids[index]] }
        case "search":
            state.page = .search
            state.searchText = argument
        case "menu":
            let path = argument.split(separator: "/").map(String.init)
            var menu = NSApp.mainMenu
            for (index, title) in path.enumerated() {
                guard let item = menu?.items.first(where: { $0.title == title }) else { log("no menu item \(title)"); return }
                if index == path.count - 1 {
                    menu?.update()
                    if let menu, let i = menu.items.firstIndex(of: item) { menu.performActionForItem(at: i) }
                } else {
                    menu = item.submenu
                    menu?.update()
                    if let menu { menu.delegate?.menuNeedsUpdate?(menu) }
                }
            }
        case "key":
            NSApp.activate()
            NSApp.windows.first { $0.title == argument }?.makeKeyAndOrderFront(nil)
        case "title":
            controller.split.detail.noteDetail?.debugType(title: argument)
        case "body":
            controller.split.detail.noteDetail?.debugType(body: argument)
        case "command":
            if let raw = Int(argument), let command = NoteCommand(rawValue: raw) { controller.split.detail.noteDetail?.perform(command) }
        case "action":
            // Sends an action up the responder chain without asking whether it is enabled.
            if !NSApp.sendAction(Selector(argument), to: nil, from: nil) { _ = controller.perform(Selector(argument), with: nil) }
        case "purge":
            // Removes notes made for testing, by their exact title.
            for note in library.notes where note.title == argument { NoteStore.deletePermanently(note, in: library.context) }
        case "dump":
            dump()
        default:
            log("unknown command \(command)")
        }
    }

    private static func dump() {
        for window in NSApp.windows {
            log("window \(window.title) visible=\(window.isVisible) frame=\(window.frame) toolbar=\(window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [])")
        }
        log("notes=\(Library.shared.notes.count) projects=\(Library.shared.projects.count)")
    }
}
#endif
