import AppKit
import SwiftData

/// One chat with the buckets: questions are answered by the chosen model from the passages of the notes that fit.
/// A chat is about all buckets or one (a new chat can choose, a held one keeps what it started with); answers
/// name the notes they come from, a click opens one. The field is at the bottom.
final class ChatViewController: NSViewController, NSTextViewDelegate {
    private let state: WindowState
    private let library = Library.shared
    private var service: ChatService { .shared }
    private var token: UUID?
    private var observers: [Observing] = []

    private let scroll = NSScrollView()
    private let transcript = NSStackView()
    private let scope = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scopeLabel = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), color: .brandProject)
    private let input = ChatInputView()
    private let send = NSButton()
    private var shownEntries: [UUID] = []
    private var shownThread: UUID?
    private var shownThinking = false
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
        let scopeRow = NSStackView.horizontal([folder, scopeLabel, scope], spacing: 6)

        input.textView.delegate = self
        input.placeholder = "Ask your buckets…"
        send.image = .symbol("arrow.up.circle.fill", size: 26, weight: .semibold, label: "Send")
        send.isBordered = false
        send.contentTintColor = .brandSky
        send.target = self
        send.action = #selector(sendTapped)
        send.toolTip = "Send"
        let inputRow = NSStackView.horizontal([input, send], spacing: 10, alignment: .bottom)

        let root = NSView()
        root.addSubview(scopeRow)
        root.addSubview(scroll)
        root.addSubview(inputRow)
        NSLayoutConstraint.activate([
            scopeRow.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 12),
            scopeRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            scroll.topAnchor.constraint(equalTo: scopeRow.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            inputRow.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            inputRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            inputRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            inputRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            transcript.topAnchor.constraint(equalTo: document.topAnchor),
            transcript.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            transcript.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        token = library.observe { [weak self] in self?.render() }
        observers.append(Observing { [weak self] in
            guard let self else { return }
            _ = (self.state.chatID, self.state.chatScope, self.service.thinking, self.service.status)
            self.render()
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

    private var thread: ChatThread? {
        state.chatID.flatMap { id in library.threads.first { $0.id == id } }
    }

    private var entries: [ChatEntry] {
        guard let id = thread?.id else { return [] }
        let descriptor = FetchDescriptor<ChatEntry>(predicate: #Predicate { $0.threadID == id }, sortBy: [SortDescriptor(\.createdAt)])
        return (try? library.context.fetch(descriptor)) ?? []
    }

    private var isThinking: Bool { thread != nil && service.thinking == thread?.id }

    // MARK: Rendering

    private func render() {
        // What the chat is about: a new chat can still choose.
        let projects = library.projects
        if let thread {
            scope.isHidden = true
            scopeLabel.isHidden = false
            scopeLabel.stringValue = ChatScope.name(thread.projectID, projects: projects)
        } else {
            scope.isHidden = false
            scopeLabel.isHidden = true
            scope.removeAllItems()
            scope.addItem(withTitle: String(localized: "All Buckets"))
            scope.lastItem?.representedObject = nil
            for project in projects where !project.isArchived {
                scope.addItem(withTitle: project.name)
                scope.lastItem?.representedObject = Projects.key(project)
            }
            if let current = state.chatScope, let index = scope.itemArray.firstIndex(where: { $0.representedObject as? String == current }) {
                scope.selectItem(at: index)
            } else {
                scope.selectItem(at: 0)
            }
        }

        let entries = entries
        let ids = entries.map(\.id)
        let thinking = isThinking
        guard !hasRendered || ids != shownEntries || thread?.id != shownThread || thinking != shownThinking || thinking else {
            send.isEnabled = service.thinking == nil
            return
        }
        hasRendered = true
        shownEntries = ids
        shownThread = thread?.id
        shownThinking = thinking
        transcript.arrangedSubviews.forEach { $0.removeFromSuperview() }
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
        DispatchQueue.main.async { [weak self] in
            guard let self, !entries.isEmpty else { return }
            self.scroll.documentView?.scroll(NSPoint(x: 0, y: max(0, (self.scroll.documentView?.frame.height ?? 0) - self.scroll.contentSize.height)))
        }
    }

    private func addIntro() {
        let empty = EmptyMessageView()
        empty.show(
            title: "Ask Your Buckets",
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
                    pill.setAccessibilityHelp("Opens the note")
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

    @objc private func scopeChosen() {
        state.chatScope = scope.selectedItem?.representedObject as? String
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

    private func ask(_ text: String) {
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
    let textView = NSTextView()
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
