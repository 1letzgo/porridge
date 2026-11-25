import AppKit
import SwiftData

/// Details of the selected entry, as on the iPhone (`EntryDetails`): Organize · Appointment · Document · Speakers ·
/// Connections · Sharing & Activity, as an AppKit form – section headers, a label column of 84 pt, values that open
/// their menu. Several selected entries show only what they have in common (`EntryDetails.commonFields`). In the
/// main window it follows the selection (the inspector's Details mode); a note in a window of its own shows its
/// Details in a popover.
final class DetailsInspectorViewController: NSViewController {
    private let state: WindowState?
    private let fixedNote: Note?
    private let library = Library.shared
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let empty = NSTextField.label("No Entry Selected", font: .systemFont(ofSize: 13, weight: .semibold), color: .secondaryLabelColor)
    private var observers: [Observing] = []
    private var libraryToken: UUID?
    private var signature = ""
    private var sectionViews: [EntryDetails.Section.Kind: NSView] = [:]
    private var pendingSection: EntryDetails.Section.Kind?

    // Connections, worked out off the main thread for the entry shown.
    private var linkedFrom: [Note] = []
    private var mentions: [Note] = []
    private var similar: [Note] = []
    private var connectionsKey: String?
    private var connectionsTask: Task<Void, Never>?

    static let labelWidth: CGFloat = 84
    private static let rowFont = NSFont.systemFont(ofSize: 12.5)
    private static let valueFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)

    /// Follows the selection of a main window.
    init(state: WindowState) {
        self.state = state
        fixedNote = nil
        super.init(nibName: nil, bundle: nil)
    }

    /// Always this note (its own window).
    init(note: Note) {
        state = nil
        fixedNote = note
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 20, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        root.addSubview(empty)
        scroll.pinEdges(to: root)
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: root.centerYAnchor),
        ])
        root.setAccessibilityLabel(String(localized: "Details"))
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Everything `render` reads (the notes, the selection, the sharing, the appointments) brings it back; it
        // rebuilds only when what it shows changed.
        observers.append(Observing { [weak self] in self?.render() })
        libraryToken = library.observe { [weak self] in self?.render() }
    }

    deinit {
        MainActor.assumeIsolated {
            observers.cancelAll()
            library.stopObserving(libraryToken)
            connectionsTask?.cancel()
        }
    }

    // MARK: What is shown

    private var notes: [Note] {
        if let fixedNote { return fixedNote.modelContext == nil && library.note(fixedNote.id) == nil ? [] : [fixedNote] }
        guard let state else { return [] }
        return state.selection.compactMap { id in
            if let draft = state.draft, draft.id == id { return draft }
            return library.note(id)
        }
    }

    private var window: NSWindow? { view.window ?? MainWindowController.frontIfAny?.window }

    /// Shows the section (when there is one entry).
    func scroll(to section: EntryDetails.Section.Kind?) {
        guard let section else {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            return
        }
        pendingSection = section
        view.layoutSubtreeIfNeeded()
        applyPendingScroll()
    }

    private func applyPendingScroll() {
        guard let section = pendingSection, let target = sectionViews[section], let document = scroll.documentView else { return }
        pendingSection = nil
        let frame = target.convert(target.bounds, to: document)
        let maxY = max(0, document.bounds.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, frame.minY - 8), maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func render() {
        let notes = notes
        if notes.count == 1, let note = notes.first {
            let context = entryContext(for: note)
            let key = Self.signature(of: note, context: context) + connectionsSignature
            refreshConnections(for: note)
            guard key != signature else { return }
            signature = key
            build(note, context: context)
        } else if notes.count > 1 {
            let key = "many:" + notes.map { "\($0.id)\($0.projectIDs)\($0.todoState)\(String(describing: $0.documentInfo))" }.joined()
            guard key != signature else { return }
            signature = key
            buildMany(notes)
        } else {
            guard signature != "none" else { return }
            signature = "none"
            setRows([])
            empty.isHidden = false
            empty.stringValue = state?.page == .chat ? "" : String(localized: "No Entry Selected")
        }
    }

    private func entryContext(for note: Note) -> EntryContext {
        var context = EntryContext.live(for: note, bowls: library.projects, processing: library.processing)
        if !note.isDeleted { context.activityLine = context.activityLine ?? OpenedActivity.line(for: note.id) }
        return context
    }

    /// What the form shows of a note (not its text): it is built again only when this changed.
    private static func signature(of note: Note, context: EntryContext) -> String {
        [
            note.id.uuidString, "\(note.projectIDs)", "\(note.todoState)", note.todoDue ?? "", note.todoRepeat?.raw ?? "",
            "\(note.tags)", String(describing: note.documentInfo), "\(note.speakers.map { $0.name + ($0.profileID ?? "") })",
            "\(note.isDeleted)", "\(context.isReadOnly)", context.appointment?.key ?? "", context.activityLine ?? "",
            "\(note.suggestedProjectIDs)", "\(context.bowls.map(\.name))", "\(note.isRecording)", "\(note.attachments.count)",
            EntryDetails.sharingText(for: note), "\(AppointmentLinks.shared.ledger.notes.count)",
        ].joined(separator: "|")
    }

    private var connectionsSignature: String {
        "\(linkedFrom.map(\.id))\(mentions.map(\.id))\(similar.map(\.id))"
    }

    /// Linked From, Mentions and Similar: worked out again only when another entry changed, came or went, or this
    /// one's title changed.
    private func refreshConnections(for note: Note) {
        guard !note.isDeleted, note.modelContext != nil else {
            linkedFrom = []
            mentions = []
            similar = []
            connectionsKey = nil
            return
        }
        let notes = library.notes
        let key = "\(note.id)-\(EntryLinks.scanSignature(for: note, among: notes))-\(NoteIndex.shared.version)"
        guard key != connectionsKey else { return }
        connectionsKey = key
        connectionsTask?.cancel()
        connectionsTask = Task { @MainActor [weak self] in
            // A moment later: opening the entry comes first.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let similar = SimilarEntries.similar(to: note, among: notes)
            let found = await EntryLinks.linkedFromAndMentions(of: note, among: notes)
            guard !Task.isCancelled, let self else { return }
            self.similar = similar
            self.linkedFrom = found.linkedFrom
            self.mentions = found.mentions
            self.render()
        }
    }

    private func setRows(_ views: [NSView]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for view in views {
            stack.addArrangedSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
        }
    }

    // MARK: One entry

    private func build(_ note: Note, context: EntryContext) {
        empty.isHidden = true
        sectionViews = [:]
        var views: [NSView] = []
        for (index, section) in EntryDetails.sections(for: note, context: context).enumerated() {
            let header = sectionHeader(section, note: note, context: context, first: index == 0)
            sectionViews[section.kind] = header
            views.append(header)
            for row in section.rows {
                views += rowViews(row, note: note, context: context)
            }
        }
        setRows(views)
        if pendingSection != nil {
            view.layoutSubtreeIfNeeded()
            applyPendingScroll()
        }
    }

    private func sectionHeader(_ section: EntryDetails.Section, note: Note, context: EntryContext, first: Bool) -> NSView {
        let title = NSTextField.label(section.kind.title.uppercased(), font: .systemFont(ofSize: 11, weight: .bold), color: .secondaryLabelColor)
        var views: [NSView] = [title, NSView()]
        if let action = section.action {
            let name: String = switch action {
            case .changeAppointment: context.appointment == nil ? String(localized: "Link…") : String(localized: "Change…")
            case .editPages: String(localized: "Edit Pages…")
            case .knownVoices: String(localized: "Known Voices…")
            }
            let button = LinkButton(title: name) { [weak self] sender in self?.run(action, note: note, from: sender) }
            button.isEnabled = action != .changeAppointment || note.modelContext != nil
            views.append(button)
        }
        let row = NSStackView.horizontal(views, spacing: 6)
        let box = NSStackView.vertical([row], spacing: 0)
        box.edgeInsets = NSEdgeInsets(top: first ? 4 : 16, left: 0, bottom: 4, right: 0)
        row.widthAnchor.constraint(equalTo: box.widthAnchor).isActive = true
        title.setAccessibilityRole(.staticText)
        box.setAccessibilityElement(false)
        return box
    }

    private func run(_ action: EntryDetails.Section.Action, note: Note, from sender: NSView) {
        switch action {
        case .changeAppointment:
            AppointmentActions.linkMenu(for: note).popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
        case .editPages:
            PDFPageEditorController.open(note, in: window)
        case .knownVoices:
            SpeakerMenu.showKnownVoices(in: window)
        }
    }

    /// The views of one row (the document's last row also brings "Clear Document Details").
    private func rowViews(_ row: EntryDetails.Row, note: Note, context: EntryContext) -> [NSView] {
        let label = EntryDetails.label(row.kind, for: note)
        let locked = row.isLocked
        let context = context
        switch row.kind {
        case .type:
            var views: [NSView] = [Self.value(EntryDetails.typeName(for: note)), NSView()]
            if EntryDetails.showsTodoSwitch(note) {
                let toggle = SwitchControl(isOn: note.isTodo) { on in TodoBridge.setTodo(on, note) }
                toggle.isEnabled = EntryDetails.canSwitchTodo(note, context: context)
                toggle.setAccessibilityLabel(String(localized: "To-do"))
                views += [Self.value(String(localized: "To-do"), color: .secondaryLabelColor), toggle]
            }
            return [Self.row(label, NSStackView.horizontal(views, spacing: 6))]
        case .bowl:
            let bowl = note.projectIDs.lazy.compactMap { context.bowl($0) }.first
            let title = bowl?.name ?? String(localized: "Inbox")
            let symbol = bowl == nil ? "tray" : "folder.fill"
            let color: NSColor = bowl == nil ? .labelColor : .brandProjectText
            if locked { return [Self.row(label, Self.value(title, symbol: symbol, color: color))] }
            let button = MenuValueButton(title: title, symbol: symbol, color: color) { [weak self] in
                NoteOperations.bucketMenu(for: [note], window: self?.window)
            }
            button.setAccessibilityLabel(String(localized: "Bowl"))
            button.setAccessibilityValue(title)
            return [Self.row(label, button)]
        case .suggestedBowl:
            guard let bowl = EntryDetails.suggestion(for: note, context: context) else { return [] }
            let name = Self.value(bowl.name, symbol: "sparkles", color: .brandProjectText)
            let file = ActionButton(title: String(localized: "File")) {
                Undoable.move([note], toBowl: Projects.key(bowl), named: bowl.name, in: Library.shared.context)
            }
            file.controlSize = .small
            file.bezelStyle = .push
            file.setAccessibilityLabel(String(localized: "File into \(bowl.name)"))
            let drop = NSButton(image: .symbol("xmark", size: 9, weight: .bold, label: "Drop Suggestion"), target: nil, action: nil)
            drop.isBordered = false
            drop.contentTintColor = .secondaryLabelColor
            drop.toolTip = String(localized: "Drop Suggestion")
            ClosureTarget.attach(to: drop) { Inbox.dismissSuggestions(note, in: Library.shared.context) }
            return [Self.row(label, NSStackView.horizontal([name, NSView(), file, drop], spacing: 6))]
        case .due:
            let title = note.todoDue.map { Todos.dueLabel($0) } ?? String(localized: "None")
            let color: NSColor = note.todoDue == nil ? .secondaryLabelColor : note.isOverdue ? .brandDangerText : .brandTaskText
            if locked { return [Self.row(label, Self.value(title, color: color))] }
            let button = MenuValueButton(title: title, symbol: nil, color: color) { [weak self] in
                DueDateMenu.make(for: [note], window: self?.window, includesRepeat: false)
            }
            button.setAccessibilityLabel(String(localized: "Due Date"))
            return [Self.row(label, button)]
        case .repeat:
            let title = note.todoRepeat?.title ?? String(localized: "Never")
            let color: NSColor = note.todoRepeat == nil ? .secondaryLabelColor : .brandTaskText
            if locked { return [Self.row(label, Self.value(title, color: color))] }
            let button = MenuValueButton(title: title, symbol: nil, color: color) { [weak self] in
                DueDateMenu.repeatItem(for: [note], window: self?.window).submenu ?? NSMenu()
            }
            button.setAccessibilityLabel(String(localized: "Repeat"))
            return [Self.row(label, button)]
        case .tags:
            let flow = FlowView()
            flow.spacing = 5
            var pills: [NSView] = note.tags.map { tag in
                let removable = !locked && note.labels.contains { $0.lowercased() == tag.lowercased() }
                let pill = PillButton(title: "#\(tag)", symbol: removable ? "xmark" : nil, tint: .systemGray, target: nil, action: nil)
                pill.labelColor = .labelColor
                pill.setAccessibilityLabel(removable ? String(localized: "Remove Tag \(tag)") : String(localized: "Tag \(tag)"))
                if removable {
                    ClosureTarget.attach(to: pill) { Undoable.removeTag(tag, from: note, in: Library.shared.context) }
                } else {
                    pill.isEnabled = false
                }
                return pill
            }
            if !locked {
                let add = PillButton(title: String(localized: "Tag"), symbol: "plus", tint: .systemGray, target: nil, action: nil)
                add.isOutlined = true
                add.labelColor = .secondaryLabelColor
                add.setAccessibilityLabel(String(localized: "Add Tag"))
                ClosureTarget.attach(to: add) { [weak self] in self?.addTag(to: note) }
                pills.append(add)
            } else if pills.isEmpty {
                pills.append(Self.value(String(localized: "None"), color: .secondaryLabelColor))
            }
            flow.setViews(pills)
            return [Self.row(label, flow, alignment: .top)]
        case .appointment:
            guard let ref = context.appointment else {
                return [Self.row(label, Self.value(String(localized: "None"), color: .secondaryLabelColor))]
            }
            let title = "\(ref.title) · \(ref.when)"
            if locked { return [Self.row(label, Self.value(title, color: .brandNavy, lines: 2))] }
            let button = MenuValueButton(title: title, symbol: "calendar", color: .brandNavy) {
                AppointmentActions.linkMenu(for: note)
            }
            button.setAccessibilityLabel(String(localized: "Appointment"))
            return [Self.row(label, button)]
        case .sameAppointment:
            let others = AppointmentLinks.shared.others(linkedWith: note, among: library.notes)
            return [Self.row(label, entriesValue(others, word: others.count == 1 ? String(localized: "1 more entry") : String(localized: "\(others.count) more entries")))]
        case .documentKind:
            let info = note.documentInfo ?? DocumentInfo()
            let title = info.kind?.title ?? String(localized: "None")
            let color: NSColor = info.kind == nil ? .secondaryLabelColor : .brandNavy
            if locked { return [Self.row(label, Self.value(title, symbol: info.kind?.symbol, color: color))] }
            let button = MenuValueButton(title: title, symbol: info.kind?.symbol, color: color) {
                Self.kindMenu(for: [note])
            }
            button.setAccessibilityLabel(String(localized: "Document Kind"))
            return [Self.row(label, button)]
        case .sender, .dated, .amount:
            let info = note.documentInfo ?? DocumentInfo()
            let value: String? = switch row.kind {
            case .sender: info.correspondent
            case .dated: info.dayText
            default: info.amountText
            }
            let color: NSColor = value == nil ? .secondaryLabelColor : .labelColor
            if locked { return [Self.row(label, Self.value(value ?? String(localized: "None"), color: color, lines: 2))] }
            let button = LinkButton(title: value ?? String(localized: "None"), color: color, font: Self.valueFont) { [weak self] _ in
                DocumentInfoSheet.edit(note, in: self?.window)
            }
            button.toolTip = String(localized: "Edit Document Details…")
            var views = [Self.row(label, button)]
            // Under the section's last row (the amount, or the date for a kind without one).
            if row.kind == (info.kind?.hasAmount ?? true ? .amount : .dated), !info.isEmpty {
                let clear = LinkButton(title: String(localized: "Clear Document Details"), color: .brandDangerText) { _ in
                    Undoable.clearDocument(note, in: Library.shared.context)
                }
                views.append(Self.row("", clear))
            }
            return views
        case .speakers:
            let flow = FlowView()
            flow.spacing = 5
            flow.setViews(note.speakers.map { speaker in
                var title = AppSettings.isMe(speaker) ? String(localized: "\(speaker.name) (Me)") : speaker.name
                if VoiceProfiles.isUnnamed(speaker) { title += " · " + String(localized: "Name…") }
                let pill = PillButton(title: title, symbol: nil, tint: .speaker(speaker.colorIndex), target: nil, action: nil)
                pill.isEnabled = !locked
                pill.setAccessibilityLabel(String(localized: "Rename \(speaker.name)"))
                ClosureTarget.attach(to: pill) { [weak self, weak pill] in
                    guard let pill else { return }
                    SpeakerMenu.make(for: speaker, in: note, window: self?.window)
                        .popUp(positioning: nil, at: NSPoint(x: 0, y: pill.bounds.height + 2), in: pill)
                }
                return pill
            })
            return [flow]
        case .linkedFrom:
            var words: [String] = []
            if !linkedFrom.isEmpty { words.append("\(linkedFrom.count)") }
            if !mentions.isEmpty { words.append(mentions.count == 1 ? String(localized: "1 Mention") : String(localized: "\(mentions.count) Mentions")) }
            guard !words.isEmpty else { return [Self.row(label, Self.value(String(localized: "None"), color: .secondaryLabelColor))] }
            let button = MenuValueButton(title: words.joined(separator: " · "), symbol: nil, color: .labelColor) { [weak self] in
                self?.linksMenu(for: note) ?? NSMenu()
            }
            return [Self.row(label, button)]
        case .similar:
            return [Self.row(label, entriesValue(similar, word: similar.count == 1 ? String(localized: "1 entry") : String(localized: "\(similar.count) entries")))]
        case .sharing:
            return [Self.row(label, Self.value(EntryDetails.sharingText(for: note), lines: 3), alignment: .firstBaseline)]
        case .activity:
            return [Self.row(label, Self.value(context.activityLine ?? "", color: .brandProjectText, lines: 3), alignment: .firstBaseline)]
        case .origin:
            return [Self.row(label, Self.value(EntryDetails.origin(for: note).value, lines: 3), alignment: .firstBaseline)]
        }
    }

    /// Entries as a menu that opens them ("None" when there are none).
    private func entriesValue(_ notes: [Note], word: String) -> NSView {
        guard !notes.isEmpty else { return Self.value(String(localized: "None"), color: .secondaryLabelColor) }
        return MenuValueButton(title: word, symbol: nil, color: .labelColor) { [weak self] in
            let menu = NSMenu()
            for other in notes { self?.addOpenItem(other, to: menu) }
            return menu
        }
    }

    private func addOpenItem(_ other: Note, to menu: NSMenu) {
        let item = menu.add(other.displayTitle, symbol: other.kindSymbol) { [weak self] in self?.open(other) }
        item.subtitle = other.createdAt.formatted(.dateTime.day().month(.abbreviated))
    }

    /// The entries linking here, then those naming it without a link: open, or make the name a link.
    private func linksMenu(for note: Note) -> NSMenu {
        let menu = NSMenu()
        if !linkedFrom.isEmpty {
            menu.addItem(.sectionHeader(title: String(localized: "Linked From")))
            for other in linkedFrom { addOpenItem(other, to: menu) }
        }
        if !mentions.isEmpty {
            menu.addItem(.sectionHeader(title: String(localized: "Mentions")))
            for other in mentions {
                let sub = NSMenu()
                sub.add(String(localized: "Open"), symbol: other.kindSymbol) { [weak self] in self?.open(other) }
                if !BowlSharing.shared.isReadOnly(other) {
                    sub.add(String(localized: "Make the Name a Link"), symbol: "link") { [weak self] in
                        if EntryLinks.linkMention(in: other, to: note) {
                            self?.connectionsKey = nil
                            self?.render()
                        }
                    }
                }
                let item = NSMenuItem(title: other.displayTitle, action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: other.kindSymbol, accessibilityDescription: nil)
                item.submenu = sub
                menu.addItem(item)
            }
        }
        return menu
    }

    private func open(_ other: Note) {
        if let state {
            state.reveal(other)
        } else if let main = MainWindowController.frontIfAny {
            main.state.reveal(other)
            main.window?.makeKeyAndOrderFront(nil)
        }
    }

    private func addTag(to note: Note) {
        Alerts.ask("New Tag", placeholder: "Tag", action: "Add", in: window) { text in
            let tag = Note.cleanTag(text)
            guard !tag.isEmpty, !note.tags.contains(where: { $0.lowercased() == tag.lowercased() }) else { return }
            note.labels.append(tag)
            note.updatedAt = Date()
            Library.shared.save()
        }
    }

    private static func kindMenu(for documents: [Note]) -> NSMenu {
        let context = Library.shared.context
        let menu = NSMenu()
        menu.add(String(localized: "Not Set")) { Undoable.apply(.kind(nil), to: documents, in: context) }
        menu.addSeparator()
        for kind in DocumentKind.allCases {
            let item = menu.add(kind.title, symbol: kind.symbol) { Undoable.apply(.kind(kind), to: documents, in: context) }
            item.state = documents.allSatisfy { $0.documentInfo?.kind == kind } ? .on : .off
        }
        return menu
    }

    // MARK: Several entries

    private func buildMany(_ notes: [Note]) {
        empty.isHidden = true
        sectionViews = [:]
        let fields = EntryDetails.commonFields(for: notes)
        let heading = NSTextField.label(String(localized: "\(notes.count) Entries Selected"), font: .systemFont(ofSize: 13, weight: .bold))
        var views: [NSView] = [heading]
        if fields.isEmpty {
            views.append(Self.value(String(localized: "Nothing of these can be changed here."), color: .secondaryLabelColor, lines: 3))
            setRows(views)
            return
        }
        let changeable = notes.filter { !$0.isDeleted && !BowlSharing.shared.isReadOnly($0) }
        let context = Library.shared.context
        views.append(sectionHeader(EntryDetails.Section(kind: .organize, rows: []), note: notes[0], context: EntryContext(), first: false))
        for field in fields {
            switch field {
            case .bowl:
                let keys = Set(changeable.map(\.projectIDs))
                let title: String
                if keys.count == 1, let key = keys.first?.first, let bowl = library.project(key: key) {
                    title = bowl.name
                } else {
                    title = keys == [[]] ? String(localized: "Inbox") : String(localized: "Several")
                }
                let button = MenuValueButton(title: title, symbol: "folder.fill", color: .brandProjectText) { [weak self] in
                    NoteOperations.bucketMenu(for: changeable, window: self?.window)
                }
                views.append(Self.row(String(localized: "Bowl"), button))
            case .later:
                let button = MenuValueButton(title: String(localized: "Later…"), symbol: "clock", color: .labelColor) { [weak self] in
                    NoteOperations.laterMenu(for: changeable, window: self?.window)
                }
                views.append(Self.row(String(localized: "Later"), button))
            case .due:
                let days = Set(changeable.map(\.todoDue))
                let title = days.count == 1 ? (days.first.flatMap { $0 }.map { Todos.dueLabel($0) } ?? String(localized: "None")) : String(localized: "Several")
                let button = MenuValueButton(title: title, symbol: nil, color: .brandTaskText) { [weak self] in
                    DueDateMenu.make(for: changeable, window: self?.window)
                }
                views.append(Self.row(String(localized: "Due"), button))
            case .documentKind:
                let kinds = Set(changeable.map { $0.documentInfo?.kind })
                let title = kinds.count == 1 ? (kinds.first.flatMap { $0 }?.title ?? String(localized: "None")) : String(localized: "Several")
                views.append(Self.row(String(localized: "Kind"), MenuValueButton(title: title, symbol: nil, color: .brandNavy) {
                    Self.kindMenu(for: changeable)
                }))
            case .sender(let count):
                views.append(Self.row("", LinkButton(title: String(localized: "Set Sender of \(count)…")) { [weak self] _ in
                    let current = Set(changeable.map { $0.documentInfo?.correspondent ?? "" })
                    Alerts.ask(
                        "Sender", message: "Leave it empty to remove the sender.", placeholder: "Company, office or person",
                        value: current.count == 1 ? current.first ?? "" : "", action: "Set", validate: { _ in true }, in: self?.window
                    ) { sender in
                        Undoable.apply(.sender(sender), to: changeable, in: context)
                    }
                }))
            case .mergePDFs(let count):
                views.append(Self.row("", LinkButton(title: String(localized: "Merge \(count) PDFs…")) { [weak self] _ in
                    NoteOperations.merge(DocumentFiles.mergeable(changeable), in: self?.window)
                }))
            case .delete(let count):
                views.append(Self.row("", LinkButton(title: String(localized: "Delete \(count)"), color: .brandDangerText) { [weak self] _ in
                    guard let state = self?.state else { return }
                    NoteOperations.trash(changeable, state: state)
                }))
            }
        }
        setRows(views)
    }

    // MARK: Pieces

    /// A row: the label in its column, then the value.
    private static func row(_ label: String, _ value: NSView, alignment: NSLayoutConstraint.Attribute = .centerY) -> NSView {
        let title = NSTextField.label(label, font: rowFont, color: .secondaryLabelColor)
        title.lineBreakMode = .byTruncatingTail
        title.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView.horizontal([title, value], spacing: 8, alignment: alignment)
        row.edgeInsets = NSEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        if !(value is NSStackView) {
            // A lone value takes the rest of the row, so long ones wrap or truncate instead of widening the column.
            value.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor).isActive = true
        }
        if value is FlowView || value is NSStackView {
            value.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
        }
        return row
    }

    private static func value(_ text: String, symbol: String? = nil, color: NSColor = .labelColor, lines: Int = 1) -> NSView {
        let field: NSTextField = lines == 1 ? NSTextField.label(text, font: valueFont, color: color) : WrappingLabel(text, font: valueFont, color: color, lines: lines)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.toolTip = text
        guard let symbol else { return field }
        let icon = NSImageView(image: .symbol(symbol, size: 11, weight: .semibold))
        icon.contentTintColor = color
        return NSStackView.horizontal([icon, field], spacing: 4)
    }
}

/// A label that wraps at the width Auto Layout gives it.
final class WrappingLabel: NSTextField {
    convenience init(_ text: String, font: NSFont, color: NSColor, lines: Int) {
        self.init(wrappingLabelWithString: text)
        self.font = font
        textColor = color
        maximumNumberOfLines = lines
        lineBreakMode = .byWordWrapping
        cell?.truncatesLastVisibleLine = true
        isSelectable = false
        translatesAutoresizingMaskIntoConstraints = false
    }

    override func layout() {
        super.layout()
        if preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// "Changed by Anna" as it was when an entry was opened here (opening it marks it as seen, so the live line is
/// gone): the head and the inspector keep showing it while the entry is open.
@MainActor
enum OpenedActivity {
    private static var lines: [UUID: String] = [:]

    static func remember(_ line: String?, for id: UUID) {
        lines[id] = line
    }

    static func line(for id: UUID) -> String? { lines[id] }
}

/// A value of the inspector that opens its menu: the word in its colour, with the pop-up chevrons.
final class MenuValueButton: NSButton {
    private let makeMenu: () -> NSMenu

    init(title: String, symbol: String?, color: NSColor, menu: @escaping () -> NSMenu) {
        makeMenu = menu
        super.init(frame: .zero)
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        let text = NSMutableAttributedString()
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [color]))) {
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: title))
        text.append(NSAttributedString(string: "  "))
        if let chevrons = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold).applying(.init(paletteColors: [.tertiaryLabelColor]))) {
            let attachment = NSTextAttachment()
            attachment.image = chevrons
            attachment.bounds = NSRect(x: 0, y: 0, width: chevrons.size.width, height: chevrons.size.height)
            text.append(NSAttributedString(attachment: attachment))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        text.addAttributes([.font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: color, .paragraphStyle: paragraph],
                           range: NSRange(location: 0, length: text.length))
        attributedTitle = text
        alignment = .left
        toolTip = title
        target = self
        action = #selector(pop)
        setAccessibilityRole(.popUpButton)
        setAccessibilityValue(title)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pop() {
        makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }
}

/// A plain text button in the inspector (sky by default), running a closure.
final class LinkButton: NSButton {
    private let handler: (NSView) -> Void

    init(title: String, color: NSColor = .brandSkyText, font: NSFont = .systemFont(ofSize: 12, weight: .semibold), handler: @escaping (NSView) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        attributedTitle = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        alignment = .left
        target = self
        action = #selector(run)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func run() { handler(self) }
}

/// A small switch that runs a closure with its new state.
final class SwitchControl: NSSwitch {
    private let handler: (Bool) -> Void

    init(isOn: Bool, handler: @escaping (Bool) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        controlSize = .mini
        state = isOn ? .on : .off
        translatesAutoresizingMaskIntoConstraints = false
        target = self
        action = #selector(changed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() { handler(state == .on) }
}
