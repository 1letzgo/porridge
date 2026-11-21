#if DEBUG
import AppKit
import SwiftData

/// Lets a developer drive the app from the command line in a debug build, for checking the interface without
/// clicking: with PORRIDGE_DEBUG_DRIVER set, commands written to `commandFile` are run. Not part of release builds.
///
/// Commands: `page inbox|todos|chat|archive|trash|search`, `bucket <name>`, `select <row>`, `menu <Top>/<Item>[/<Sub>]`,
/// `search <text>`, `dump`, `shot <path.png>`, `key <window title>` (orders a window front), `title <text>` / `body <text>` (types
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
            case "todos": state.page = .todos
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
        case "seed-todos":
            // Four open to-dos as the iOS test seed makes them: long overdue (in a new bowl named like the
            // prefix), today, upcoming (in five days), no date.
            let bucket = Projects.create(argument, in: library.context)
            let today = Date()
            let soon = Calendar.current.date(byAdding: .day, value: 5, to: today) ?? today
            for (name, due) in [("long overdue", "2000-01-01"), ("today", Todos.dueKey(today)), ("upcoming", Todos.dueKey(soon)), ("no date", nil)] as [(String, String?)] {
                let todo = Note()
                todo.title = "\(argument) \(name)"
                todo.titleIsCustom = true
                todo.source = .note
                todo.todoState = .open
                todo.todoDueDay = due
                if due == "2000-01-01", let bucket {
                    todo.projectIDs = [Projects.key(bucket)]
                    todo.filedAt = today
                }
                library.context.insert(todo)
            }
            library.save()
        case "purge-prefix":
            // Removes the test to-dos and the bowl "seed-todos" made.
            for note in library.notes where note.title.hasPrefix(argument + " ") { NoteStore.deletePermanently(note, in: library.context) }
            for project in library.projects where project.name == argument { Projects.delete(project, in: library.context) }
        case "seed-meeting":
            // A summarized meeting whose summary has three tasks (the user's, somebody else's with a date,
            // nobody's), as the iOS test seed makes it but without a bowl.
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
            // Makes a bowl the way "New Bowl…" does once its name is given; "!" before the name pins it.
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
        case "quit":
            // A regular quit, so the windows' state is written for the next launch.
            NSApp.terminate(nil)
        case "dump":
            dump()
        case "shot":
            // `shot <path.png>`: the front window as the app draws it, without asking for screen recording; an open
            // sheet goes to `<path>-sheet.png`.
            func shoot(_ window: NSWindow?, _ path: String) {
                guard let content = window?.contentView?.superview ?? window?.contentView,
                      let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { log("shot: no window"); return }
                content.cacheDisplay(in: content.bounds, to: bitmap)
                do {
                    try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    log("shot: \(path)")
                } catch {
                    log("shot: \(error.localizedDescription)")
                }
            }
            shoot(controller.window, argument)
            if let sheet = controller.window?.attachedSheet { shoot(sheet, (argument as NSString).deletingPathExtension + "-sheet.png") }
        case "select-all":
            // Every row of the list, as Command-A does.
            state.selection = NoteListContent.build(for: state, library: library).sections.flatMap(\.1).compactMap {
                if case .note(let id) = $0 { id } else { nil }
            }
        case "context-menu":
            // The context menu of the selected notes, as titles (submenus indented).
            let menu = NSMenu()
            NoteOperations.addItems(for: state.selection.compactMap(library.note), to: menu, state: state, window: controller.window)
            func list(_ menu: NSMenu, _ indent: String) {
                for item in menu.items where !item.isSeparatorItem {
                    log(indent + item.title + (item.state == .on ? " ✓" : ""))
                    if let sub = item.submenu { list(sub, indent + "  ") }
                }
            }
            list(menu, "")
            log("--")
        case "pages":
            // The page editor of the open note's PDF.
            if let note = controller.openNote { PDFPageEditorController.open(note, in: controller.window) } else { log("pages: no note") }
        case "drop", "hover":
            // `drop list|detail <path>|text:<words>[|<path>…]`: a drop from outside through the column's own drop
            // methods (`ImportDropView`); `hover` stops before the drop and leaves the highlight showing.
            let bits = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard bits.count == 2 else { log("drop: pane and items needed"); return }
            // `editor` is the open note's text, which hands files on to the column around it.
            func editor(in view: NSView) -> NSView? {
                if view is NotePlatformTextView { return view }
                for sub in view.subviews { if let found = editor(in: sub) { return found } }
                return nil
            }
            let target: NSView
            switch bits[0] {
            case "detail": target = controller.split.detail.view
            case "editor":
                guard let found = editor(in: controller.split.detail.view) else { log("drop: no editor"); return }
                target = found
            default: target = controller.split.content.view
            }
            let pasteboard = NSPasteboard(name: .init("PorridgeDebugDrop"))
            pasteboard.clearContents()
            let items = bits[1].split(separator: "|").map(String.init)
            if let text = items.first, text.hasPrefix("text:") {
                pasteboard.setString(String(text.dropFirst(5)), forType: .string)
            } else {
                pasteboard.writeObjects(items.map { URL(fileURLWithPath: $0) as NSURL })
            }
            let info = DebugDraggingInfo(pasteboard: pasteboard, window: controller.window, location: target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil))
            guard let destination = target as? NSDraggingDestination else { return }
            let operation = destination.draggingEntered?(info) ?? []
            log("drop entered: operation=\(operation.rawValue)")
            guard parts.first == "drop" else { return }
            if destination.prepareForDragOperation?(info) == true {
                log("drop performed: \(destination.performDragOperation?(info) ?? false)")
            } else {
                destination.draggingExited?(info)
                log("drop refused")
            }
            destination.draggingEnded?(info)
        case "seed-chat":
            // The chat test entries (`TestSeed.seedChat`); only on test data.
            TestSeed.seedChat(library.context)
            library.setNeedsReload()
        case "ask":
            // Asks the open chat (a new one when none is open), as typing the question and Return does.
            state.page = .chat
            DispatchQueue.main.async {
                let chat = controller.split.detail.children.compactMap { $0 as? ChatViewController }.first
                if chat == nil { log("ask: no chat") }
                chat?.ask(argument)
                log("model: \(SummaryModel.chat)")
            }
        case "chat-model":
            // `chat-model <SummaryModel.id>|default`: the chat's own model, as the menu in the chat sets it; logs the list.
            SummaryModel.chatChoice = SummaryModel.available.first { $0.id == argument }
            log("models: \(SummaryModel.available.map(\.id).joined(separator: ", "))")
            log("default: \(SummaryModel.current.id) chat: \(SummaryModel.chat.id)")
        case "new-chat":
            state.chatID = nil
        case "chat-dump":
            // The open chat's questions and answers with their sources, in order.
            guard let id = state.chatID else { log("chat-dump: no chat"); return }
            let entries = ((try? library.context.fetch(FetchDescriptor<ChatEntry>())) ?? [])
                .filter { $0.threadID == id }.sorted { $0.createdAt < $1.createdAt }
            for entry in entries {
                log("[\(entry.role.rawValue)\(entry.isError ? " ERROR" : "")] \(entry.text)")
                for source in entry.sources { log("   source: \(source.title) \(source.noteID)") }
            }
            log("--")
        case "chat-source":
            // Clicks the n-th source button (0 = first) of the open chat, as a click on it does.
            func buttons(in view: NSView) -> [NSButton] {
                var found: [NSButton] = []
                if let button = view as? NSButton, button.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) != nil { found.append(button) }
                for sub in view.subviews { found += buttons(in: sub) }
                return found
            }
            let all = buttons(in: controller.split.detail.view)
            let index = Int(argument) ?? 0
            guard index < all.count else { log("chat-source: \(all.count) sources"); return }
            log("chat-source: \(all[index].title)")
            all[index].performClick(nil)
            DispatchQueue.main.async { log("page=\(state.page) open=\(state.openNoteID.flatMap { library.note($0)?.title } ?? "none")") }
        case "dismiss":
            // Closes the sheet on the window (a notice) with its first button.
            if let window = controller.window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        case "hover-end":
            for view in [controller.split.content.view, controller.split.detail.view] {
                (view as? NSDraggingDestination)?.draggingExited?(nil)
            }
        default:
            log("unknown command \(command)")
        }
    }

    private static var nextSequence = 1000

    /// A drag that did not come from the mouse, for `drop`.
    final class DebugDraggingInfo: NSObject, NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        let draggingDestinationWindow: NSWindow?
        let draggingLocation: NSPoint
        let draggingSequenceNumber: Int
        @MainActor init(pasteboard: NSPasteboard, window: NSWindow?, location: NSPoint) {
            draggingPasteboard = pasteboard
            draggingDestinationWindow = window
            draggingLocation = location
            DebugDriver.nextSequence += 1
            draggingSequenceNumber = DebugDriver.nextSequence
        }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggedImageLocation: NSPoint { draggingLocation }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    private static func dump() {
        for window in NSApp.windows {
            log("window \(window.title) visible=\(window.isVisible) frame=\(window.frame) toolbar=\(window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [])")
        }
        log("notes=\(Library.shared.notes.count) projects=\(Library.shared.projects.count)")
    }
}
#endif
