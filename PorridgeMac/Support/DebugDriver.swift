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
                    // Through the window's responder chain, also while the app is in the background.
                    if item.target == nil, let action = item.action, let responder = controller.window?.firstResponder {
                        let ok = controller.validateMenuItem(item)
                        log("menu item \(title) enabled=\(ok)")
                        if ok, !responder.tryToPerform(action, with: item) { _ = controller.tryToPerform(action, with: item) }
                    } else if let menu, let i = menu.items.firstIndex(of: item) {
                        menu.performActionForItem(at: i)
                    }
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
        case "suggest":
            controller.split.detail.noteDetail?.debugSuggestions(argument)
        case "seed-meeting":
            // A summarized meeting whose summary has three tasks (the user's, somebody else's with a date,
            // nobody's), as the iOS test seed makes it but without a bucket.
            let meeting = Note()
            meeting.title = argument
            meeting.titleIsCustom = true
            meeting.source = .meeting
            meeting.segments = [TranscriptSegment(start: 0, end: 5, text: "Let's wrap up.")]
            let due = Todos.dueKey(Calendar.current.date(byAdding: .day, value: 3, to: Date()) ?? Date())
            meeting.summary = """
            ## Summary
            The team planned the launch.

            ## Action Items
            - [ ] Send the offer to the customer – \(AppSettings.myName ?? "Me")
            - [ ] Book the venue – Anna – \(due)
            - [ ] Update the roadmap
            """
            meeting.summaryModel = "Test"
            meeting.summarizedAt = Date()
            TodoSuggestions.offer(meeting)
            library.context.insert(meeting)
            library.save()
            state.page = .inbox
            state.open(meeting.id)
        case "purge-from":
            // Removes the to-dos made from a test meeting (by its title), then the meeting.
            for meeting in library.notes where meeting.title == argument {
                for todo in library.notes where todo.todoSourceID == meeting.id.uuidString { NoteStore.deletePermanently(todo, in: library.context) }
                NoteStore.deletePermanently(meeting, in: library.context)
            }
        case "bucket-new":
            // Makes a bucket the way "New Bucket…" does once its name is given; "!" before the name pins it.
            let pinned = argument.hasPrefix("!")
            if let project = Projects.create(pinned ? String(argument.dropFirst()) : argument, in: library.context), pinned {
                project.isPinned = true
                library.save()
            }
        case "bucket-delete":
            for project in library.projects where project.name == argument { Projects.delete(project, in: library.context) }
        case "sidebar":
            log("sidebar: " + controller.split.sidebar.debugRows.joined(separator: " | "))
        case "filter":
            state.kindFilter = KindFilter(rawValue: argument)
        case "due":
            // Sets the due day ("yyyy-MM-dd", or "clear") of the selected to-dos.
            TodoBridge.setDue(argument == "clear" ? nil : argument, controller.selectedNotes)
        case "appearance":
            NSApp.appearance = argument == "dark" ? NSAppearance(named: .darkAqua) : argument == "light" ? NSAppearance(named: .aqua) : nil
        case "settings":
            SettingsWindowController.shared.show(tab: argument.isEmpty ? nil : argument)
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
