import AppKit
import SwiftData

/// One chat with the bowls: questions are answered by the chosen model from the passages of the notes that fit.
/// A chat is about all bowls, the Inbox or one bowl, changeable at any time (it holds from the next question on;
/// earlier answers keep their sources); answers name the notes they come from, a click opens one. The field is at
/// the bottom. A question handed over by Search or Ask (`WindowState.pendingQuestion`) is asked in a new chat.
final class ChatViewController: NSViewController, NSTextViewDelegate {
    private let state: WindowState
    private let library = Library.shared
    private var service: ChatService { .shared }
    private var token: UUID?
    private var observers: [Observing] = []

    private let scroll = NSScrollView()
    private let transcript = NSStackView()
    /// A conversation from the top; the intro of an empty chat in the middle of the visible room.
    private var transcriptAtTop: NSLayoutConstraint!
    private var transcriptInMiddle: NSLayoutConstraint!
    private let scope = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Where the answers go when the chat's model is not on this Mac (`SummaryModel.sendsHint`).
    private let hintLabel = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, lines: 2)
    /// Which model answers, and a quick way to choose another: the same choice as "Chat Model" in Settings.
    private let modelPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let input = ChatInputView()
    private let send = NSButton()
    private var shownEntries: [UUID] = []
    private var shownThread: UUID?
    private var shownThinking = false
    private var shownActions: [UUID: [ChatAction]] = [:]
    private var hasRendered = false

    private let examples = [
        "What did we decide in the last meetings?",
        "Which tasks are still open?",
        "Summarize what came in this week",
    ]

    init(state: WindowState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        transcript.orientation = .vertical
        transcript.alignment = .leading
        transcript.spacing = 14
        transcript.edgeInsets = NSEdgeInsets(top: 14, left: 24, bottom: 14, right: 24)
        transcript.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(transcript)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        scope.target = self
        scope.action = #selector(scopeChosen)
        scope.controlSize = .small
        scope.setAccessibilityLabel("Chat About")
        let folder = NSImageView(image: .symbol("folder.fill", size: 11, weight: .bold))
        folder.contentTintColor = .brandProject
        let scopeRow = NSStackView.horizontal([folder, scope], spacing: 6)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        modelPopUp.target = self
        modelPopUp.action = #selector(modelChosen)
        modelPopUp.controlSize = .small
        modelPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        modelPopUp.setAccessibilityLabel("Chat Model")
        modelPopUp.translatesAutoresizingMaskIntoConstraints = false

        input.textView.delegate = self
        input.placeholder = "Ask your bowls…"
        send.image = .symbol("arrow.up.circle.fill", size: 26, weight: .semibold, label: "Send")
        send.isBordered = false
        send.contentTintColor = .brandSky
        send.target = self
        send.action = #selector(sendTapped)
        send.toolTip = "Send"
        let inputRow = NSStackView.horizontal([input, send], spacing: 10, alignment: .bottom)

        let root = NSView()
        root.addSubview(scopeRow)
        root.addSubview(modelPopUp)
        root.addSubview(hintLabel)
        root.addSubview(scroll)
        root.addSubview(inputRow)
        NSLayoutConstraint.activate([
            scopeRow.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 12),
            scopeRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            modelPopUp.centerYAnchor.constraint(equalTo: scopeRow.centerYAnchor),
            modelPopUp.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            modelPopUp.leadingAnchor.constraint(greaterThanOrEqualTo: scopeRow.trailingAnchor, constant: 12),
            hintLabel.topAnchor.constraint(equalTo: scopeRow.bottomAnchor, constant: 4),
            hintLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            inputRow.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            inputRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            inputRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            inputRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            transcript.topAnchor.constraint(greaterThanOrEqualTo: document.topAnchor),
            transcript.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            transcript.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
            // At least the visible height, else as tall as the transcript: the intro of an empty chat stands in its
            // middle, a conversation starts at the top.
            document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
        ])
        let fitsTranscript = document.heightAnchor.constraint(equalTo: transcript.heightAnchor)
        fitsTranscript.priority = .defaultLow
        fitsTranscript.isActive = true
        transcriptAtTop = transcript.topAnchor.constraint(equalTo: document.topAnchor)
        transcriptInMiddle = transcript.centerYAnchor.constraint(equalTo: document.centerYAnchor)
        transcriptInMiddle.priority = .defaultHigh
        transcriptAtTop.isActive = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        token = library.observe { [weak self] in self?.render() }
        observers.append(Observing { [weak self] in
            guard let self else { return }
            _ = (self.state.chatID, self.state.chatScope, self.service.thinking, self.service.status, self.service.actions)
            self.render()
        })
        observers.append(Observing { [weak self] in
            guard let self, let question = self.state.pendingQuestion else { return }
            DispatchQueue.main.async { self.takePendingQuestion(question) }
        })
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(input.textView)
    }

    override func removeFromParent() {
        library.stopObserving(token)
        observers.cancelAll()
        // Left: the model the chat loaded gives its memory back.
        service.release()
        super.removeFromParent()
    }

    /// The chat started by the last question, until the lists are fetched again: a second question sent at once
    /// goes into it instead of starting another one.
    private var newThread: ChatThread?

    private var thread: ChatThread? {
        guard let id = state.chatID else { return nil }
        if let thread = library.threads.first(where: { $0.id == id }) { return thread }
        return newThread?.id == id && newThread?.modelContext != nil ? newThread : nil
    }

    private var entries: [ChatEntry] {
        guard let id = thread?.id else { return [] }
        let descriptor = FetchDescriptor<ChatEntry>(predicate: #Predicate { $0.threadID == id }, sortBy: [SortDescriptor(\.createdAt)])
        return (try? library.context.fetch(descriptor)) ?? []
    }

    private var isThinking: Bool { thread != nil && service.thinking == thread?.id }

    // MARK: Rendering

    /// "Same as Default (<name>)", then the models of the list; hidden when there is none.
    private func renderModel() {
        let models = SummaryModel.available
        modelPopUp.isHidden = models.isEmpty
        let titles = ["Same as Default (\(SummaryModel.current.name))"] + models.map(\.menuTitle)
        if modelPopUp.itemTitles != titles {
            modelPopUp.removeAllItems()
            modelPopUp.addItems(withTitles: titles)
        }
        let chosen = SummaryModel.chatChoice.flatMap { models.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        if modelPopUp.indexOfSelectedItem != chosen { modelPopUp.selectItem(at: chosen) }
        let hint = SummaryModel.chat.sendsHint("question and excerpts of your notes")
        modelPopUp.toolTip = hint ?? "Answers on this device"
        hintLabel.stringValue = hint ?? ""
        hintLabel.isHidden = hint == nil
    }

    /// Search or Ask handed over a question: a new chat about the chosen scope asks it.
    private func takePendingQuestion(_ question: String) {
        guard state.pendingQuestion == question, service.thinking == nil else { return }
        state.pendingQuestion = nil
        state.chatID = nil
        ask(question)
    }

    @objc private func modelChosen() {
        let models = SummaryModel.available
        let index = modelPopUp.indexOfSelectedItem
        SummaryModel.chatChoice = index > 0 && index <= models.count ? models[index - 1] : nil
        renderModel()
    }

    private func render() {
        // What the chat is about: changeable at any time.
        let projects = library.projects
        let current = thread?.projectID ?? state.chatScope
        scope.removeAllItems()
        scope.addItem(withTitle: String(localized: "All Bowls"))
        scope.lastItem?.representedObject = nil
        scope.addItem(withTitle: String(localized: "Inbox"))
        scope.lastItem?.representedObject = SearchAsk.inboxKey
        for project in projects where !project.isArchived || Projects.key(project) == current {
            scope.addItem(withTitle: project.name)
            scope.lastItem?.representedObject = Projects.key(project)
        }
        if let current, let index = scope.itemArray.firstIndex(where: { $0.representedObject as? String == current }) {
            scope.selectItem(at: index)
        } else {
            scope.selectItem(at: 0)
        }

        renderModel()

        let entries = entries
        let ids = entries.map(\.id)
        let thinking = isThinking
        let actions = Dictionary(ids.compactMap { id in service.actions[id].map { (id, $0) } }, uniquingKeysWith: { first, _ in first })
        guard !hasRendered || ids != shownEntries || thread?.id != shownThread || thinking != shownThinking || thinking || actions != shownActions else {
            send.isEnabled = service.thinking == nil
            return
        }
        // Only a card changed: the place in the transcript stays.
        let onlyCards = hasRendered && ids == shownEntries && thread?.id == shownThread && thinking == shownThinking && !thinking
        hasRendered = true
        shownEntries = ids
        shownThread = thread?.id
        shownThinking = thinking
        shownActions = actions
        transcript.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Only the intro: centered, across and up and down.
        let introOnly = entries.isEmpty && !thinking
        transcriptAtTop.isActive = !introOnly
        transcriptInMiddle.isActive = introOnly
        transcript.alignment = introOnly ? .centerX : .leading
        if entries.isEmpty { addIntro() }
        for entry in entries { addBubble(entry) }
        if thinking {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let label = NSTextField.label(service.status.isEmpty ? "Thinking…" : service.status, color: .secondaryLabelColor)
            transcript.addArrangedSubview(NSStackView.horizontal([spinner, label], spacing: 10))
        }
        send.isEnabled = service.thinking == nil
        // The newest message stays in view; an empty chat starts at the top.
        let scrollPosition = scroll.contentView.bounds.origin
        DispatchQueue.main.async { [weak self] in
            guard let self, !entries.isEmpty else { return }
            if onlyCards {
                self.scroll.contentView.scroll(to: scrollPosition)
                return
            }
            self.scroll.documentView?.scroll(NSPoint(x: 0, y: max(0, (self.scroll.documentView?.frame.height ?? 0) - self.scroll.contentSize.height)))
        }
    }

    private func addIntro() {
        let empty = EmptyMessageView()
        empty.show(
            title: "Ask Your Bowls",
            message: "Ask about anything in your notes, meetings, links, images and files. The answer comes from your own data.",
            symbol: "bubble.left.and.text.bubble.right"
        )
        transcript.addArrangedSubview(empty)
        empty.heightAnchor.constraint(equalToConstant: 200).isActive = true
        empty.widthAnchor.constraint(equalTo: transcript.widthAnchor, constant: -48).isActive = true
        for example in examples {
            let button = PillButton(title: example, tint: .brandSky, target: self, action: #selector(exampleTapped(_:)))
            transcript.addArrangedSubview(button)
        }
    }

    private func addBubble(_ entry: ChatEntry) {
        switch entry.role {
        case .user:
            let text = NSTextField(wrappingLabelWithString: entry.text)
            text.font = .preferredFont(forTextStyle: .body)
            text.isSelectable = true
            text.translatesAutoresizingMaskIntoConstraints = false
            let bubble = BubbleView(content: text, tint: .brandSky)
            let row = NSStackView.horizontal([NSView(), bubble], spacing: 0)
            transcript.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: transcript.widthAnchor, constant: -48),
                bubble.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.82),
            ])
        case .assistant:
            var parts: [NSView] = []
            if entry.isError {
                let label = NSTextField.label("⚠︎ " + entry.text, color: .brandDangerText, lines: 0)
                parts.append(label)
            } else {
                let text = SummaryTextView()
                text.show(entry.text)
                parts.append(text)
                // The changes the answer proposes, to confirm.
                let actions = service.actions(for: entry.id)
                if !actions.isEmpty {
                    let cards = ChatActionCardsView(actions: actions)
                    let entryID = entry.id
                    cards.onConfirm = { [weak self] id in
                        guard let self else { return }
                        self.service.confirm(id.map { [$0] }, in: entryID, context: self.library.context)
                    }
                    cards.onCancel = { [weak self] id in
                        self?.service.cancel(id.map { [$0] }, in: entryID)
                    }
                    parts.append(cards)
                }
            }
            let sources = entry.sources
            if !sources.isEmpty {
                let flow = FlowView()
                flow.translatesAutoresizingMaskIntoConstraints = false
                flow.setViews(sources.map { source in
                    // The source wears the symbol of its kind, as in the lists.
                    let symbol = library.note(source.noteID)?.kindSymbol ?? "doc.text"
                    let pill = PillButton(title: source.title, symbol: symbol, tint: .brandSky, target: self, action: #selector(openSource(_:)))
                    pill.identifier = .init(source.noteID.uuidString)
                    // Gone since (deleted, or a copy of a bowl that was left): shown, not opened.
                    let isGone = library.note(source.noteID) == nil
                    pill.isEnabled = !isGone
                    pill.setAccessibilityHelp(isGone ? "The note is gone" : "Opens the note")
                    return pill
                })
                parts.append(flow)
            }
            let column = NSStackView.vertical(parts, spacing: 12)
            transcript.addArrangedSubview(column)
            column.widthAnchor.constraint(equalTo: transcript.widthAnchor, constant: -72).isActive = true
            for part in parts { part.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        }
    }

    // MARK: Actions

    /// Another scope: a new chat starts with it, a running one asks the next question about it.
    @objc private func scopeChosen() {
        let key = scope.selectedItem?.representedObject as? String
        state.chatScope = key
        if let thread, thread.projectID != key {
            thread.projectID = key
            library.save()
        }
    }

    @objc private func exampleTapped(_ sender: NSButton) {
        ask(sender.title)
    }

    @objc private func sendTapped() {
        ask(input.textView.string)
    }

    @objc private func openSource(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }), let note = library.note(id) else { return }
        state.reveal(note)
    }

    func ask(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, service.thinking == nil else { return }
        input.textView.string = ""
        input.textDidChange()
        // A new chat is kept from its first question on.
        let chat: ChatThread
        if let thread {
            chat = thread
        } else {
            chat = ChatThread(projectID: state.chatScope)
            library.context.insert(chat)
            library.save()
            newThread = chat
            state.chatID = chat.id
        }
        let notes = library.notes
        let projects = library.projects
        let context = library.context
        Task { @MainActor in await service.ask(question, in: chat, notes: notes, projects: projects, context: context) }
    }

    /// Return sends, Shift-Return or Option-Return makes a new line.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) { return false }
            sendTapped()
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        input.textDidChange()
    }
}

/// A rounded tint around a view: the questions of a chat.
final class BubbleView: NSView {
    private let tint: NSColor

    init(content: NSView, tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        addSubview(content)
        content.pinEdges(to: self, insets: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = tint.withAlphaComponent(0.16).resolved(for: self)
    }
}

/// The chat's field: grows with its text up to a few lines, with a placeholder.
final class ChatInputView: NSView {
    let textView = ChatInputTextView()
    private let scroll = NSScrollView()
    private let placeholderLabel = NSTextField.label(color: .placeholderTextColor)
    private var height: NSLayoutConstraint!

    var placeholder: String {
        get { placeholderLabel.stringValue }
        set {
            placeholderLabel.stringValue = newValue
            textView.setAccessibilityPlaceholderValue(newValue)
        }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        textView.font = .preferredFont(forTextStyle: .body)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("Question")
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        addSubview(placeholderLabel)
        scroll.pinEdges(to: self, insets: NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8))
        height = heightAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            height,
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 11),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.resolved(for: self)
        layer?.borderColor = NSColor.separatorColor.resolved(for: self)
    }

    func textDidChange() {
        placeholderLabel.isHidden = !textView.string.isEmpty
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height + 20
        height.constant = min(max(40, used), 120)
    }
}

/// The chat field's text view: files and pictures dragged onto it are not put in as text, they go to the detail
/// around it, which imports them (`ImportDropView`).
final class ChatInputTextView: NSTextView {
    private func fileDropTarget(_ sender: NSDraggingInfo) -> NSDraggingDestination? {
        guard sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil else { return nil }
        var view = superview
        while let current = view {
            if current is ImportDropView { return current }
            view = current.superview
        }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileDropTarget(sender)?.draggingEntered?(sender) ?? super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileDropTarget(sender)?.draggingUpdated?(sender) ?? super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender, let target = fileDropTarget(sender) { target.draggingExited?(sender); return }
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileDropTarget(sender)?.prepareForDragOperation?(sender) ?? super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        fileDropTarget(sender)?.performDragOperation?(sender) ?? super.performDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if let sender, fileDropTarget(sender) != nil { return }
        super.concludeDragOperation(sender)
    }
}
