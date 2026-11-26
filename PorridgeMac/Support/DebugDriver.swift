#if DEBUG
import AppKit
import SwiftData

/// Lets a developer drive the app from the command line in a debug build, for checking the interface without
/// clicking: with PORRIDGE_DEBUG_DRIVER set, commands written to `commandFile` are run. Not part of release builds.
///
/// Commands: `page today|inbox|bowls|todos|chat|archive|trash|search`, `search-ask <text>`, `search-ask-key …`,
/// `shot-ask <path.png>`, `shot-settings <path.png>`, `bucket <name>`, `select <row>`, `menu <Top>/<Item>[/<Sub>]`,
/// `search <text>`, `dump`, `shot <path.png>`, `key <window title>` (orders a window front), `title <text>` / `body <text>` (types
/// into the open note), `settings <tab>`, `settings-rows` (the open Settings tab's rows), `rewrite-bar` (✦ of the format bar,
/// logging what it showed), `dismiss`, `import-meeting <file>` (a stereo file as a meeting with the Mac's sound),
/// `speakers <title>` (that meeting's speakers and transcript). Commands also run while a menu or a modal alert is open.
@MainActor
enum DebugDriver {
    /// The file the commands are read from (one per line), and the file answers go to.
    static let commandFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("porridge-debug-commands")
    static let outputFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("porridge-debug-output")
    private static var timer: Timer?

    static func start() {
        guard ProcessInfo.processInfo.environment["PORRIDGE_DEBUG_DRIVER"] != nil else { return }
        try? FileManager.default.removeItem(at: commandFile)
        let timer = Timer(timeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let text = try? String(contentsOf: commandFile, encoding: .utf8), !text.isEmpty else { return }
                try? FileManager.default.removeItem(at: commandFile)
                for line in text.split(separator: "\n") { run(String(line)) }
            }
        }
        // In the common modes: commands still run while a menu is open or an alert runs modally (`dismiss`
        // closes them), instead of waiting until someone clicks it away.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The window and its child panels (the results of Search or Ask, the toast) in one picture.
    static func shotWithPanels(_ window: NSWindow?, _ path: String) {
        guard let window, let content = window.contentView?.superview ?? window.contentView,
              let base = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { log("shot: no window"); return }
        content.cacheDisplay(in: content.bounds, to: base)
        let size = window.frame.size
        let image = NSImage(size: size)
        image.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))
        for child in window.childWindows ?? [] where child.isVisible {
            guard let view = child.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let origin = NSPoint(x: child.frame.minX - window.frame.minX, y: child.frame.minY - window.frame.minY)
            NSColor.black.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: NSRect(origin: origin, size: child.frame.size).offsetBy(dx: 0, dy: -3), xRadius: 12, yRadius: 12).fill()
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: NSRect(origin: origin, size: child.frame.size), xRadius: 12, yRadius: 12).fill()
            bitmap.draw(in: NSRect(origin: origin, size: child.frame.size))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { log("shot: no image"); return }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            log("shot: \(path)")
        } catch {
            log("shot: \(error.localizedDescription)")
        }
    }

    /// The visible texts of a view tree, in order.
    static func texts(_ view: NSView) -> [String] {
        var found: [String] = []
        if let field = view as? NSTextField, !field.isHidden, !field.stringValue.isEmpty { found.append(field.stringValue) }
        for sub in view.subviews where !sub.isHidden { found += texts(sub) }
        return found
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
            case "today": state.page = .today
            case "bowls": state.page = .bowls
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
        case "bucket-archive":
            // Archives the bowl of that name (test data for the Bowls place and the archive).
            for project in library.projects where project.name == argument { Archive.set(true, project, in: library.context) }
        case "smart-filter":
            // `smart-filter <name>`: a smart filter for meetings, named so.
            _ = SmartFilterStore.shared.add(name: argument, criteria: SmartFilterCriteria(kind: .meetings))
        case "list":
            // The rows of the middle column as built: "[section]" then the items.
            let built = NoteListContent.build(for: state, library: library)
            var rows: [String] = []
            for (section, items) in built.sections {
                rows.append("[\(section.title)\(section.footnote.map { " – " + $0 } ?? "")]")
                for item in items {
                    switch item {
                    case .note(let id): rows.append(library.note(id)?.displayTitle ?? "?")
                    case .project(let id): rows.append("bowl " + (library.project(id)?.name ?? "?"))
                    case .appointment(let key): rows.append("appointment " + key)
                    case .link(let link): rows.append("link \(link)")
                    }
                }
            }
            log("list \(state.page): " + (rows.isEmpty ? "empty – \(built.emptyTitle)" : rows.joined(separator: " | ")))
        case "plus-menu":
            // The toolbar's "+" menu as titles.
            guard let item = controller.window?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "new" }) as? NSMenuToolbarItem else { log("plus-menu: none"); return }
            item.menu.update()
            log("plus-menu: " + item.menu.items.map { $0.isSeparatorItem ? "|" : $0.title + ($0.keyEquivalent.isEmpty ? "" : " ⌘" + $0.keyEquivalent) }.joined(separator: " · "))
        case "shot-sidebar":
            // The sidebar alone, drawn into an image (its window material does not come out in `shot`).
            let view = controller.split.sidebar.view
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { log("shot-sidebar: none"); return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: argument))
            log("shot-sidebar: \(argument)")
        case "toolbar":
            log("toolbar: " + (controller.window?.toolbar?.items.map(\.itemIdentifier.rawValue).joined(separator: ", ") ?? "none"))
        case "bucket-delete":
            for project in library.projects where project.name == argument { Projects.delete(project, in: library.context) }
        case "sidebar":
            log("sidebar: " + controller.split.sidebar.debugRows.joined(separator: " | "))
            log("sidebar geometry: " + controller.split.sidebar.debugGeometry)
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
        case "fake-appointment":
            // `fake-appointment <title>`: an appointment of the next hour, in memory only, linked to the open note.
            let start = Date().addingTimeInterval(600)
            let appointment = CalendarAppointment(id: "debug-\(argument)", title: argument, start: start, end: start.addingTimeInterval(3600), isAllDay: false, calendarName: "Debug", externalID: "debug-\(argument)")
            TodayCalendar.shared.addForTesting(appointment)
            if let note = library.notes.first(where: { !$0.isDeleted && $0.isRecording }) { AppointmentLinks.shared.link(note, to: appointment, in: nil) }
            if let note = library.notes.first(where: { !$0.isDeleted && !$0.isRecording && !$0.isTodo }) { AppointmentLinks.shared.link(note, to: appointment, in: nil) }
        case "fake-appointment-clear":
            // Takes the links of `fake-appointment` away again.
            for note in library.notes where AppointmentLinks.shared.appointment(for: note.id)?.seriesID.hasPrefix("debug-") == true {
                AppointmentLinks.shared.link(note, to: nil, in: nil)
            }
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
        case "shot-settings":
            // `shot-settings <path.png>`: the Settings window (open it first with `settings <tab>`).
            let window = SettingsWindowController.shared.window
            guard let content = window?.contentView?.superview ?? window?.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { log("shot-settings: no window"); break }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: argument))
            log("shot-settings: \(argument)")
        case "settings-rows":
            // The open Settings tab's form: every row's frame (hidden ones marked), to check its spacing.
            guard let pane = (SettingsWindowController.shared.contentViewController as? NSTabViewController).flatMap({
                $0.selectedTabViewItemIndex >= 0 ? $0.tabViewItems[$0.selectedTabViewItemIndex].viewController as? SettingsPane : nil
            }) else { log("settings-rows: none"); break }
            let grid = pane.form.grid
            log("settings-rows: grid=\(grid.frame) fitting=\(grid.fittingSize) ambiguous=\(grid.hasAmbiguousLayout)")
            for index in 0..<grid.numberOfRows {
                let row = grid.row(at: index)
                let views = (0..<grid.numberOfColumns).compactMap { row.cell(at: $0).contentView }
                let text = views.flatMap(texts).first ?? String(describing: type(of: views.last ?? NSView()))
                log("  \(index)\(row.isHidden ? " (hidden)" : "") \(text): \(views.map { "\($0.frame.integral)" }.joined(separator: " "))")
            }
        case "search-ask":
            // `search-ask <text>`: ⌘K, then the text typed into the toolbar's field; the results hang below it.
            controller.debugSearchAsk(argument)
            DispatchQueue.main.async { log((CommandBarController.current?.dump ?? ["search-ask: no results"]).joined(separator: "\n")) }
        case "search-ask-floating":
            // The floating panel (the global shortcut, no toolbar).
            CommandBarController.show(for: controller)
            log((CommandBarController.current?.dump ?? []).joined(separator: "\n"))
        case "search-ask-dump":
            log((CommandBarController.current?.dump ?? ["search-ask-dump: closed"]).joined(separator: "\n"))
        case "search-ask-key":
            // `search-ask-key return|ask|all|down|up|escape`: ↩, ⌘↩, ⇧↩, the arrows and Escape in the field.
            guard let bar = CommandBarController.current else { log("search-ask-key: closed"); return }
            switch argument {
            case "ask": bar.ask()
            case "all": bar.showAll()
            case "down": _ = bar.handle(#selector(NSResponder.moveDown(_:)))
            case "up": _ = bar.handle(#selector(NSResponder.moveUp(_:)))
            case "escape": _ = bar.handle(#selector(NSResponder.cancelOperation(_:)))
            default: bar.runSelected()
            }
        case "windows":
            // The window's number and frame and those of its child panels, for `screencapture -l`.
            guard let window = controller.window else { return }
            log("window \(window.windowNumber) \(Int(window.frame.minX)) \(Int(window.frame.minY)) \(Int(window.frame.width)) \(Int(window.frame.height))")
            for child in window.childWindows ?? [] where child.isVisible {
                log("child \(child.windowNumber) \(Int(child.frame.minX)) \(Int(child.frame.minY)) \(Int(child.frame.width)) \(Int(child.frame.height))")
            }
        case "shot-ask":
            // `shot-ask <path.png>`: the window with the results of Search or Ask drawn where they hang.
            shotWithPanels(controller.window, argument)
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
        case "chat-thread":
            // A chat with a question and an answer (only on test data), for `chat-delete`.
            guard DataLocation.testFolder != nil else { log("chat-thread: test data only"); return }
            let thread = ChatThread()
            thread.title = argument.isEmpty ? "Open invoices" : argument
            library.context.insert(thread)
            library.context.insert(ChatEntry(threadID: thread.id, role: .user, text: "Which invoices are open?"))
            library.context.insert(ChatEntry(threadID: thread.id, role: .assistant, text: "Two, both from Telekom."))
            library.save()
        case "chat-delete":
            // "Delete Chat" on a row of the chat list (0 = first), with its question.
            state.page = .chat
            controller.split.content.chats.debugDelete(row: Int(argument) ?? 0)
        case "chat-count":
            log("chats: \(((try? library.context.fetch(FetchDescriptor<ChatThread>())) ?? []).map(\.title))")
        case "toast":
            // The undo toast with a message of its own, as any action offers it.
            UndoToast.shared.offer(argument.isEmpty ? "Moved to “Kitchen Renovation”" : argument, systemImage: "folder") { log("toast: undone") }
        case "toast-state":
            log("toast: \(UndoToast.shared.current?.message ?? "none")")
        case "shot-toast":
            // The undo toast's own window (a child of the main window, outside `shot`).
            guard let panel = UndoToastPanel.shared.debugWindow, let content = panel.contentView,
                  let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { log("shot-toast: no toast"); return }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: argument))
            log("shot-toast: \(argument)")
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
            // Closes the sheet on the window (a notice) with its first button, and an alert running modally.
            if let window = controller.window, let sheet = window.attachedSheet {
                log("dismiss: \(sheet.title.isEmpty ? (sheet.contentView.map(texts).map { $0.prefix(3).joined(separator: " · ") } ?? "sheet") : sheet.title)")
                window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            }
            if NSApp.modalWindow != nil {
                log("dismiss: modal \(NSApp.modalWindow?.title ?? "")")
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
            }
        case "rewrite-bar":
            // ✦ of the open entry's format bar, as a click on it does; logs what it showed ("ask: …" is a sheet on
            // the window, closed with `dismiss`).
            guard let detail = controller.split.detail.noteDetail else { log("rewrite-bar: no entry"); return }
            log("rewrite-bar: \(detail.debugRewriteFromBar())")
        case "seed-kinds":
            // One entry of every kind (`TestSeed.seedEntryKinds`); only on test data.
            guard DataLocation.testFolder != nil else { log("seed-kinds: test data only"); return }
            TestSeed.seedEntryKinds(library.context)
            library.setNeedsReload()
        case "tick":
            // `tick <title>`: the box of that to-do's row, as a click on it does (in Today it leaves with Undo).
            guard let note = library.notes.first(where: { $0.title == argument }) else { log("tick: none"); return }
            Todos.tick(note, leavesList: state.page == .today, in: library.context)
        case "seed-inbox":
            // The Inbox of the mockups (`TestSeed.seedInbox`); only on test data.
            guard DataLocation.testFolder != nil else { log("seed-inbox: test data only"); return }
            TestSeed.seedInbox(library.context)
            library.setNeedsReload()
        case "scroll-end":
            // The end of the middle column.
            let table = controller.split.content.notes.table
            if table.numberOfRows > 0 { table.scrollRowToVisible(table.numberOfRows - 1) }
        case "triage":
            // Triage on or off (the Inbox's "Triage"); `triage-key f|l|d|j|k|delete|escape` presses a key.
            controller.split.content.notes.toggleTriage()
        case "triage-key":
            let codes: [String: (UInt16, String)] = [
                "f": (3, "f"), "l": (37, "l"), "d": (2, "d"), "j": (38, "j"), "k": (40, "k"), "delete": (51, "\u{7f}"), "escape": (53, "\u{1b}"),
            ]
            guard let (code, chars) = codes[argument],
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: controller.window?.windowNumber ?? 0,
                                               context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { log("triage-key: ?"); return }
            controller.split.content.notes.table.keyDown(with: event)
            DispatchQueue.main.async { log("triage-key: selection=\(state.selection.compactMap { library.note($0)?.title })") }
        case "open-kind":
            // `open-kind meeting|todo|pdf|link|note|image`: opens that entry of `seed-kinds`.
            guard let id = TestSeed.KindID.named(argument), let note = library.note(id) else { log("open-kind: none"); return }
            state.reveal(note)
        case "inspector":
            // `inspector details|record|close|toggle`.
            switch argument {
            case "record": controller.split.show(.record)
            case "close": if controller.split.isInspectorOpen { controller.split.toggleInspector(nil) }
            case "toggle": controller.split.toggleInspector(nil)
            default: controller.split.show(.details)
            }
        case "details":
            // `details <section>`: Details at a section, as a click on a value of the meta line does.
            controller.split.showDetails(at: EntryDetails.Section.Kind(rawValue: argument))
        case "toggle-sidebar":
            controller.split.toggleSidebar(nil)
        case "window-width":
            // `window-width <pt>`: the front window this wide (the height stays).
            guard let window = controller.window, let width = Double(argument) else { return }
            var frame = window.frame
            frame.size.width = max(CGFloat(width), window.minSize.width)
            window.setFrame(frame, display: true)
        case "layout":
            let views = controller.split.splitView.arrangedSubviews.map { "\(Int($0.frame.width))\($0.isHidden ? "(hidden)" : "")" }
            log("layout: window=\(Int(controller.window?.frame.width ?? 0)) columns=\(views) inspector=\(controller.split.isInspectorOpen ? "\(controller.split.inspector.mode)" : "closed")")
        case "meta":
            func find(_ view: NSView) -> MetaLineView? {
                if let meta = view as? MetaLineView { return meta }
                for sub in view.subviews { if let found = find(sub) { return found } }
                return nil
            }
            log("meta: " + (find(controller.split.detail.view)?.debugText ?? "none"))
        case "select-many":
            // The first n rows of the list, as ⌘-clicks do.
            let ids = NoteListContent.build(for: state, library: library).sections.flatMap(\.1).compactMap { item -> UUID? in
                if case .note(let id) = item { return id }
                return nil
            }
            state.selection = Array(ids.prefix(Int(argument) ?? 2))
        case "menu-dump":
            // `menu-dump Entry|AI|File|Format`: the menu bar menu as titles, validated for the open entry (dimmed
            // rows marked "(off)", hidden ones left out), submenus indented.
            guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == argument })?.submenu else { log("menu-dump: none"); return }
            log("== \(argument) ==")
            dumpMenu(menu, controller: controller, indent: "")
            log("--")
        case "toolbar-menu":
            // `toolbar-menu ai|more`: the toolbar's ✦ AI or ⋯ for the open entry, as titles.
            guard let note = controller.openNote else { log("toolbar-menu: no entry"); return }
            let menu = NSMenu()
            EntryToolbarMenu.items(argument == "ai" ? .ai : .more, for: note, in: controller).forEach(menu.addItem)
            log("== toolbar \(argument) · \(EntryKind(note)) \(note.isDeleted ? "deleted" : "") ==")
            dumpMenu(menu, controller: controller, indent: "")
            log("share: \(EntryMenus.share(for: note).map { "\($0)" } ?? "none")")
            log("--")
        case "toolbar-run":
            // `toolbar-run ai|more <title>`: runs a row of the toolbar's ✦ AI or ⋯ as a click on it does.
            let bits = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard bits.count == 2, let note = controller.openNote else { log("toolbar-run: kind and title needed"); return }
            let rows = EntryToolbarMenu.items(bits[0] == "ai" ? .ai : .more, for: note, in: controller)
            guard let row = rows.first(where: { $0.title == bits[1] }), let action = row.action else { log("toolbar-run: no row \(bits[1])"); return }
            let enabled = isEnabled(row, controller: controller)
            log("toolbar-run \(bits[1]) enabled=\(enabled)")
            guard enabled else { return }
            if !NSApp.sendAction(action, to: nil, from: row) { _ = controller.tryToPerform(action, with: row) }
            DispatchQueue.main.async {
                log("after: page=\(state.page) open=\(controller.openNote?.title ?? "none") pinned=\(controller.openNote?.isPinned ?? false)")
            }
        case "view-only":
            // `view-only on|off`: the open entry's bowl is treated as shared with me to view only (in memory).
            BowlSharing.shared.debugReadOnly = argument == "on" ? controller.openNote?.projectIDs.first : nil
        case "trash-open":
            // Moves the open entry to Recently Deleted and keeps it open there (test data only).
            guard DataLocation.testFolder != nil, let note = controller.openNote else { log("trash-open: test data only"); return }
            NoteStore.trash(note, in: library.context)
            state.page = .trash
            state.selection = [note.id]
        case "recover-open":
            guard let note = controller.openNote else { return }
            NoteStore.restore(note, in: library.context)
            state.reveal(note)
        case "import-meeting":
            // `import-meeting <file>`: a stereo audio file as a meeting recorded on the Mac with its sound (left the
            // microphone, the user; right the Mac's sound, the others), transcribed the way such a recording is.
            // `scripts/make-meeting-fixture.sh` makes one.
            let url = URL(fileURLWithPath: argument)
            do {
                let fileName = try AudioStore.importFile(from: url)
                let note = Note()
                note.source = .meeting
                note.title = url.deletingPathExtension().lastPathComponent
                note.titleIsCustom = true
                note.statusRaw = ProcessingStatus.recorded.rawValue
                note.audioFileName = fileName
                note.inputName = SystemAudioMix.inputName
                if let info = AudioStore.audioInfo(for: fileName) {
                    note.duration = info.duration
                    note.channelCount = info.channels
                }
                note.speakerMode = .channels
                note.speakers = [
                    Speaker(id: SpeakerAssigner.leftChannelID, name: AppSettings.myName ?? "Me", colorIndex: 0),
                    Speaker(id: SpeakerAssigner.rightChannelID, name: SystemAudioMix.othersName, colorIndex: 1),
                ]
                library.context.insert(note)
                library.save()
                library.processing.enqueue(.transcript(note.id))
                state.reveal(note)
                log("import-meeting: \(note.title) \(note.id) channels=\(note.channelCount)")
            } catch {
                log("import-meeting: \(error.localizedDescription)")
            }
        case "speakers":
            // `speakers <title>`: the meeting's state, speakers (id, name, seconds of voice) and transcript by speaker.
            guard let note = library.notes.first(where: { $0.title == argument && !$0.isDeleted }) else { log("speakers: none"); return }
            log("speakers: \(note.title) status=\(note.status.rawValue) mode=\(note.speakerMode.rawValue) error=\(note.errorMessage ?? "none")")
            for speaker in note.speakers {
                log("  \(speaker.id) \(speaker.name) voice=\(String(format: "%.1f", speaker.voiceSeconds ?? 0))s profile=\(speaker.profileID == nil ? "no" : "yes")")
            }
            for segment in note.segments {
                log("  [\(segment.speakerId ?? "-")] \(String(format: "%.1f–%.1f", segment.start, segment.end)) \(segment.text)")
            }
            log("--")
        case "hover-end":
            for view in [controller.split.content.view, controller.split.detail.view] {
                (view as? NSDraggingDestination)?.draggingExited?(nil)
            }
        default:
            log("unknown command \(command)")
        }
    }

    /// Writes a menu's rows: dimmed ones "(off)", hidden ones left out, ticks "✓", key equivalents in brackets.
    private static func dumpMenu(_ menu: NSMenu, controller: MainWindowController, indent: String) {
        menu.delegate?.menuNeedsUpdate?(menu)
        for item in menu.items {
            if item.isSeparatorItem { log(indent + "———"); continue }
            let enabled = isEnabled(item, controller: controller)
            if item.isHidden { continue }
            var key = ""
            if !item.keyEquivalent.isEmpty {
                let mods = item.keyEquivalentModifierMask
                key = (mods.contains(.control) ? "⌃" : "") + (mods.contains(.option) ? "⌥" : "") + (mods.contains(.shift) ? "⇧" : "") + (mods.contains(.command) ? "⌘" : "")
                key += item.keyEquivalent == "\u{8}" ? "⌫" : item.keyEquivalent.uppercased()
                key = " [\(key)]"
            }
            log(indent + item.title + key + (item.state == .on ? " ✓" : "") + (enabled ? "" : " (off)") + (item.submenu != nil ? " ▸" : ""))
            if let sub = item.submenu, enabled { dumpMenu(sub, controller: controller, indent: indent + "    ") }
        }
    }

    /// Whether a row is enabled as the menu bar would show it: its own target, else the first responder of the window
    /// that answers its action.
    private static func isEnabled(_ item: NSMenuItem, controller: MainWindowController) -> Bool {
        guard let action = item.action else { return item.submenu != nil || item.isEnabled }
        if let target = item.target as AnyObject? {
            if let validating = target as? NSMenuItemValidation { return validating.validateMenuItem(item) }
            return item.isEnabled
        }
        var responder: NSResponder? = controller.window?.firstResponder
        while let current = responder {
            if current.responds(to: action) {
                if let validating = current as? NSMenuItemValidation { return validating.validateMenuItem(item) }
                return true
            }
            responder = current.nextResponder
        }
        if controller.responds(to: action) { return controller.validateMenuItem(item) }
        if NSApp.delegate?.responds(to: action) == true { return true }
        return false
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
        let today = TodayCalendar.shared
        log("calendar=\(today.status) appointments=\(today.appointments.map(\.title)) todos=\(TodayTodos.open(Library.shared.notes).count) links=\(AppointmentLinks.shared.ledger.notes.count)")
    }
}
#endif
