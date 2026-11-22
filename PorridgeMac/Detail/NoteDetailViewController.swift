import AppKit
import AVFoundation
import SwiftData

private enum NoteTab: Int {
    case summary, note, transcript, article
}

/// One note: its head stays in place (title, link, date, bowls and tags, files, state, speakers), below it the
/// tab that is chosen scrolls on its own: the summary, the text, the transcript or the article. A meeting's
/// recording plays from the bar at the bottom; the microphone dictates into the text.
final class NoteDetailViewController: NSViewController, NSTextFieldDelegate {
    let note: Note
    private let state: WindowState
    private let startsRecording: Bool
    private let library = Library.shared
    private var processing: ProcessingService { library.processing }

    private let player = AudioPlayback()
    private let dictation = InlineDictation()
    private var dictationStart = 0
    private var liveText = ""
    private var tab = NoteTab.note
    private var didChooseTab = false
    private var observers: [Observing] = []
    private var libraryToken: UUID?
    private var shownErrors = Set<String>()
    private var isFetchingAudio = false
    private var fetchAudioError: String?
    private var fetchTask: Task<Void, Never>?

    // Head
    private let todoBox = TodoCheckboxButton()
    private let titleField = NSTextField()
    private let sourcePill = PillButton(title: "", symbol: "arrow.turn.up.left", tint: .brandSky, target: nil, action: nil)
    private let linkButton = NSButton()
    private let meta = NSTextField.label(color: .secondaryLabelColor, lines: 2)
    private let deletedBanner = NSStackView()
    /// In a bowl shared with me to view only.
    private let readOnlyBanner = NSStackView()
    /// "New from Anna", "Changed by Ben": until the note was open here once.
    private let activityLabel = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), color: .brandProject.readable)
    private let chips = NoteChipsView()
    private var openedActivity: String?
    private let attachments = AttachmentStripView()
    private let statusPanel = PanelView()
    private let speakers = FlowView()
    private let enhancedBanner = PanelView()
    /// After "Split into Bowl…": what it made, while it can be taken back.
    private let splitBanner = PanelView()
    private var lastSplit: BowlChange?
    private let tabs = NSSegmentedControl()
    private var tabOrder: [NoteTab] = []

    // Content
    private let content = NSView()
    private var editor: NoteEditorView!
    private let addSubtask = ActionButton(title: "Add Subtask", symbol: "plus.circle") {}
    private let taskBar = TaskDetectionBarView()
    private let dictationPreview = NSTextView()
    private let dictationPreviewScroll = NSScrollView()
    private let dictationStatus = NSTextField.label(font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), color: .controlAccentColor)
    private let summaryScroll = NSScrollView()
    private let summaryStack = NSStackView()
    private let summaryText = SummaryTextView()
    private let suggestedTodos = SuggestedTodosView()
    private let madeTodos = MadeTodosView()
    private let summaryModelLabel = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
    private let summaryEmpty = NSStackView()
    private let summaryEmptyMessage = NSTextField.label(color: .secondaryLabelColor, lines: 0)
    private let summarizeButton = PillButton(title: "Summarize", symbol: "sparkles", tint: .brandSky, target: nil, action: nil)
    private let summarizing = NSStackView()
    private let summarizingMessage = NSTextField.label(color: .secondaryLabelColor, lines: 0)
    private let summarizingDetail = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, lines: 2)
    private let summaryMenuButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let transcript = TranscriptView()
    private let articleScroll = NSScrollView()
    private let articleText = NSTextView()
    private let articleMessage = NSTextField.label(color: .secondaryLabelColor, lines: 0)

    // Bottom
    private lazy var playerBar = PlayerBarView(player: player)
    /// The entries most like this one, under the page.
    private let similar = SimilarEntriesView()
    /// The entries that link here, and those that name it without a link.
    private let entryLinks = EntryLinksView()
    private let fetchBar = NSStackView()
    private let fetchButton = PillButton(title: "Download Recording", symbol: "arrow.down.circle", tint: .brandSky, target: nil, action: nil)
    private let fetchMessage = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .brandDangerText)
    private let micButton = MicButton()
    private let micTime = NSTextField.label(font: .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold), color: .brandNavy)
    private var micTimer: Timer?

    init(note: Note, state: WindowState, startsRecording: Bool) {
        self.note = note
        self.state = state
        self.startsRecording = startsRecording
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Building

    override func loadView() {
        let root = NSView()
        let page = NSView()
        page.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(page)

        // Title, with the to-do's box before it.
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.font = .systemFont(ofSize: 22, weight: .bold)
        titleField.textColor = .brandNavy
        titleField.lineBreakMode = .byWordWrapping
        titleField.usesSingleLineMode = false
        titleField.cell?.wraps = true
        titleField.cell?.isScrollable = false
        titleField.delegate = self
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setAccessibilityLabel("Title")
        todoBox.target = self
        todoBox.action = #selector(toggleDone)
        todoBox.translatesAutoresizingMaskIntoConstraints = false
        let titleRow = NSStackView.horizontal([todoBox, titleField], spacing: 10, alignment: .top)

        sourcePill.target = self
        sourcePill.action = #selector(openSource)
        linkButton.isBordered = false
        linkButton.imagePosition = .imageLeading
        linkButton.target = self
        linkButton.action = #selector(openLink)
        linkButton.contentTintColor = .brandLinkText

        let recover = ActionButton(title: "Recover") { [weak self] in self?.recover() }
        let deletedLabel = NSTextField.label("In Recently Deleted", font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), color: .brandDangerText)
        let deletedIcon = NSImageView(image: .symbol("trash", size: 13, label: nil))
        deletedIcon.contentTintColor = .brandDangerText
        deletedBanner.setViews([deletedIcon, deletedLabel, NSView(), recover], in: .leading)
        deletedBanner.orientation = .horizontal
        deletedBanner.spacing = 8
        let readOnlyLabel = NSTextField.label("Shared with you to view only", font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), color: .secondaryLabelColor)
        let readOnlyIcon = NSImageView(image: .symbol("eye", size: 13, label: nil))
        readOnlyIcon.contentTintColor = .secondaryLabelColor
        readOnlyBanner.setViews([readOnlyIcon, readOnlyLabel, NSView()], in: .leading)
        readOnlyBanner.orientation = .horizontal
        readOnlyBanner.spacing = 8
        readOnlyBanner.isHidden = true
        activityLabel.isHidden = true

        chips.onAddTag = { [weak self] in self?.addTag() }
        attachments.onRemove = { [weak self] in self?.removeAttachment($0) }

        tabs.segmentStyle = .automatic
        tabs.trackingMode = .selectOne
        tabs.target = self
        tabs.action = #selector(tabChosen)
        tabs.setAccessibilityLabel("Show")

        let head = NSStackView.vertical(
            [titleRow, sourcePill, linkButton, meta, activityLabel, deletedBanner, readOnlyBanner, chips, attachments, statusPanel, speakers, enhancedBanner, splitBanner, tabs],
            spacing: 10
        )
        head.setCustomSpacing(4, after: titleRow)
        head.setCustomSpacing(4, after: linkButton)
        head.setCustomSpacing(14, after: enhancedBanner)
        head.setCustomSpacing(14, after: splitBanner)
        head.setCustomSpacing(14, after: speakers)

        content.translatesAutoresizingMaskIntoConstraints = false
        buildContent()

        fetchButton.target = self
        fetchButton.action = #selector(fetchRecording)
        fetchBar.setViews([fetchButton, fetchMessage], in: .leading)
        fetchBar.orientation = .vertical
        fetchBar.alignment = .centerX
        fetchBar.spacing = 6
        playerBar.onDelete = { [weak self] in self?.confirmDeleteRecording() }
        similar.onOpen = { [weak self] other in self?.state.reveal(other) }
        entryLinks.onOpen = { [weak self] other in self?.state.reveal(other) }
        entryLinks.onChange = { [weak self] in self?.renderEntryLinks() }
        let bottom = NSStackView.vertical([entryLinks, similar, playerBar, fetchBar], spacing: 8, alignment: .leading)

        page.addSubview(head)
        page.addSubview(content)
        page.addSubview(bottom)

        micButton.target = self
        micButton.action = #selector(toggleDictationAction)
        micTime.wantsLayer = true
        micTime.isHidden = true
        root.addSubview(micButton)
        root.addSubview(micTime)

        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 14),
            page.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            page.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            page.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 24),
            page.widthAnchor.constraint(lessThanOrEqualToConstant: 820),
            {
                let wide = page.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24)
                wide.priority = .defaultHigh
                return wide
            }(),
            head.topAnchor.constraint(equalTo: page.topAnchor),
            head.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            head.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            titleRow.widthAnchor.constraint(equalTo: head.widthAnchor),
            chips.widthAnchor.constraint(equalTo: head.widthAnchor),
            attachments.widthAnchor.constraint(equalTo: head.widthAnchor),
            statusPanel.widthAnchor.constraint(equalTo: head.widthAnchor),
            speakers.widthAnchor.constraint(equalTo: head.widthAnchor),
            enhancedBanner.widthAnchor.constraint(equalTo: head.widthAnchor),
            splitBanner.widthAnchor.constraint(equalTo: head.widthAnchor),
            deletedBanner.widthAnchor.constraint(equalTo: head.widthAnchor),
            readOnlyBanner.widthAnchor.constraint(equalTo: head.widthAnchor),
            meta.widthAnchor.constraint(lessThanOrEqualTo: head.widthAnchor),
            todoBox.widthAnchor.constraint(equalToConstant: 28),
            todoBox.heightAnchor.constraint(equalToConstant: 28),
            content.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            bottom.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 8),
            bottom.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: page.bottomAnchor),
            playerBar.widthAnchor.constraint(equalTo: bottom.widthAnchor),
            // Room on the right for the microphone's button, which lies over the corner.
            similar.widthAnchor.constraint(equalTo: bottom.widthAnchor, constant: -72),
            entryLinks.widthAnchor.constraint(equalTo: bottom.widthAnchor, constant: -72),
            fetchBar.widthAnchor.constraint(equalTo: bottom.widthAnchor),
            micButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            micButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            micTime.trailingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: -10),
            micTime.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),
        ])
        view = root
    }

    private func buildContent() {
        // Note: the editor, the dictation's preview while it runs.
        let note = note
        editor = NoteEditorView(get: { note.text }, set: { [weak self] text in self?.setText(text) })
        editor.controller.attachImage = { [weak self] url in
            guard let self else { return nil }
            return NoteImageAttaching.attach(url, to: note, context: self.library.context, processing: self.processing)
        }
        editor.controller.hasAttachment = { name in note.attachments.contains { $0.fileName == name } }
        // "[[" links another entry; a click on a link opens it.
        editor.controller.linkCandidates = { [weak self] query in
            guard let self else { return [] }
            return EntryLinks.candidates(for: query, among: self.library.notes, excluding: note.id)
        }
        editor.controller.openEntry = { [weak self] id in
            guard let self, let other = self.library.note(id), !other.isDeleted else { return }
            self.editor.flush()
            self.state.reveal(other)
        }
        addSubtask.setHandler { [weak self] in self?.editor.appendChecklistItem() }
        addSubtask.isBordered = false
        addSubtask.contentTintColor = .brandTaskText
        addSubtask.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        // Lines that read like tasks, offered as to-dos under the text (never on links or saved files).
        taskBar.beforeChange = { [weak self] in self?.editor.flush() }
        taskBar.afterChange = { [weak self] in
            self?.editor.reloadIfChanged()
            self?.library.save()
        }
        editor.footer = NSStackView.vertical([addSubtask, taskBar], spacing: 4)

        dictationPreview.isEditable = false
        dictationPreview.isSelectable = false
        dictationPreview.drawsBackground = false
        dictationPreview.textContainerInset = NSSize(width: 0, height: 6)
        dictationPreview.textContainer?.lineFragmentPadding = 0
        dictationPreview.isVerticallyResizable = true
        dictationPreview.autoresizingMask = [.width]
        dictationPreviewScroll.documentView = dictationPreview
        dictationPreviewScroll.hasVerticalScroller = true
        dictationPreviewScroll.drawsBackground = false
        dictationPreviewScroll.translatesAutoresizingMaskIntoConstraints = false

        // Summary: the text with its menu, or what is being done, or the offer to write one.
        summaryText.onToggleTask = { [weak self] line in
            guard let self else { return }
            SummaryTasks.toggleLine(line, of: self.note, in: self.library.context)
        }
        summaryMenuButton.isBordered = false
        summaryMenuButton.addItem(withTitle: "")
        summaryMenuButton.item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Summary Options")
        summaryMenuButton.setAccessibilityLabel("Summary Options")
        summaryMenuButton.toolTip = "Summary Options"
        let menu = summaryMenuButton.menu!
        menu.add("Edit Summary", symbol: "pencil") { [weak self] in self?.perform(.editSummary) }
        menu.add("Insert into Note", symbol: "text.insert") { [weak self] in self?.perform(.insertSummary) }
        menu.add("Copy", symbol: "doc.on.doc") { [weak self] in self?.perform(.copySummary) }
        menu.addItem(.separator())
        menu.add("Delete Summary…", symbol: "trash", isDestructive: true) { [weak self] in self?.perform(.deleteSummary) }
        let summaryHead = NSStackView.horizontal([summaryText, summaryMenuButton], spacing: 12, alignment: .top)
        summaryText.setContentHuggingPriority(.defaultLow, for: .horizontal)
        summaryText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        summarizeButton.target = self
        summarizeButton.action = #selector(requestSummaryAction)
        let sparkles = NSImageView(image: .symbol("sparkles", size: 36, weight: .light))
        sparkles.contentTintColor = .brandSkyText
        summaryEmptyMessage.alignment = .center
        summaryEmpty.setViews([sparkles, summaryEmptyMessage, summarizeButton], in: .center)
        summaryEmpty.orientation = .vertical
        summaryEmpty.spacing = 14
        summaryEmpty.edgeInsets = NSEdgeInsets(top: 24, left: 0, bottom: 24, right: 0)

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        let pulse = NSImageView(image: .symbol("sparkles", size: 36, weight: .light))
        pulse.contentTintColor = .brandSkyText
        pulse.addSymbolEffect(.pulse)
        summarizingMessage.alignment = .center
        summarizingDetail.alignment = .center
        summarizing.setViews([pulse, summarizingMessage, spinner, summarizingDetail], in: .center)
        summarizing.orientation = .vertical
        summarizing.spacing = 14
        summarizing.edgeInsets = NSEdgeInsets(top: 24, left: 0, bottom: 24, right: 0)

        madeTodos.onOpen = { [weak self] todo in self?.state.reveal(todo) }
        summaryStack.setViews([suggestedTodos, summaryHead, summaryModelLabel, madeTodos, summarizing, summaryEmpty], in: .top)
        summaryStack.setCustomSpacing(16, after: suggestedTodos)
        summaryStack.setCustomSpacing(18, after: summaryModelLabel)
        summaryStack.orientation = .vertical
        summaryStack.alignment = .leading
        summaryStack.spacing = 12
        summaryStack.translatesAutoresizingMaskIntoConstraints = false
        let summaryDocument = FlippedView()
        summaryDocument.translatesAutoresizingMaskIntoConstraints = false
        summaryDocument.addSubview(summaryStack)
        summaryScroll.documentView = summaryDocument
        summaryScroll.hasVerticalScroller = true
        summaryScroll.autohidesScrollers = true
        summaryScroll.drawsBackground = false
        summaryScroll.translatesAutoresizingMaskIntoConstraints = false

        // Article: the page's text, selectable.
        articleText.isEditable = false
        articleText.isSelectable = true
        articleText.drawsBackground = false
        articleText.font = .preferredFont(forTextStyle: .body)
        articleText.textColor = .labelColor
        articleText.textContainerInset = NSSize(width: 0, height: 4)
        articleText.textContainer?.lineFragmentPadding = 0
        articleText.isVerticallyResizable = true
        articleText.autoresizingMask = [.width]
        articleText.usesFindBar = true
        articleText.setAccessibilityLabel("Article")
        articleScroll.documentView = articleText
        articleScroll.hasVerticalScroller = true
        articleScroll.autohidesScrollers = true
        articleScroll.drawsBackground = false
        articleScroll.translatesAutoresizingMaskIntoConstraints = false

        transcript.onPlay = { [weak self] segment in
            self?.player.seek(to: segment.start)
            self?.player.play()
        }
        transcript.onAssign = { [weak self] segment, speaker in self?.reassign(segment, to: speaker) }

        for view in [editor!, dictationPreviewScroll, summaryScroll, transcript, articleScroll, dictationStatus] as [NSView] {
            content.addSubview(view)
        }
        content.addSubview(articleMessage)
        for view in [editor!, summaryScroll, transcript, articleScroll] as [NSView] {
            view.pinEdges(to: content)
        }
        NSLayoutConstraint.activate([
            dictationStatus.topAnchor.constraint(equalTo: content.topAnchor),
            dictationStatus.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dictationPreviewScroll.topAnchor.constraint(equalTo: dictationStatus.bottomAnchor, constant: 8),
            dictationPreviewScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dictationPreviewScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dictationPreviewScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            articleMessage.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            articleMessage.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            articleMessage.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
            summaryDocument.topAnchor.constraint(equalTo: summaryScroll.contentView.topAnchor),
            summaryDocument.leadingAnchor.constraint(equalTo: summaryScroll.contentView.leadingAnchor),
            summaryDocument.widthAnchor.constraint(equalTo: summaryScroll.contentView.widthAnchor),
            summaryStack.topAnchor.constraint(equalTo: summaryDocument.topAnchor),
            summaryStack.leadingAnchor.constraint(equalTo: summaryDocument.leadingAnchor),
            summaryStack.trailingAnchor.constraint(equalTo: summaryDocument.trailingAnchor, constant: -4),
            summaryStack.bottomAnchor.constraint(equalTo: summaryDocument.bottomAnchor, constant: -12),
            summaryHead.widthAnchor.constraint(equalTo: summaryStack.widthAnchor),
            suggestedTodos.widthAnchor.constraint(equalTo: summaryStack.widthAnchor),
            madeTodos.widthAnchor.constraint(equalTo: summaryStack.widthAnchor),
            summaryEmpty.widthAnchor.constraint(equalTo: summaryStack.widthAnchor),
            summarizing.widthAnchor.constraint(equalTo: summaryStack.widthAnchor),
            summaryEmptyMessage.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            summarizingMessage.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    // MARK: Life

    override func viewDidLoad() {
        super.viewDidLoad()
        chips.hostWindow = view.window
        tab = opensOnSummary || isSummarizing ? .summary : .note
        if let name = note.audioFileName, note.hasLocalAudio { player.load(AudioStore.url(for: name)) }
        // A recording in iCloud is downloaded when its note is opened, then it plays.
        fetchRecordingIfNeeded()
        // Load the speech model right away so the first piece is transcribed without delay.
        Task { try? await ModelManager.shared.ensureASR() }
        dictation.onLiveText = { [weak self] text in
            self?.liveText = text
            self?.renderDictationPreview()
        }
        dictation.onStopRequested = { [weak self] in Task { await self?.finishDictation() } }
        // What someone else added or changed: said once more here, and seen from now on.
        openedActivity = BowlSharing.shared.activityLine(for: note)
        BowlSharing.shared.markSeen(note)
        observers.append(Observing { [weak self] in self?.render() })
        taskBar.schedule(for: note, immediately: true)
        // Other notes count too: the to-dos made from this one, its bowls.
        libraryToken = library.observe { [weak self] in
            guard let self else { return }
            // Deleted for good (here or on another device): the window closes it; reading it now would trap.
            guard self.note.modelContext == nil || self.library.note(self.note.id) != nil else { return }
            self.render()
            self.renderSimilar()
            self.renderEntryLinks()
        }
        renderEntryLinks()
        // The similar entries follow the index (worked out again only when it changed).
        observers.append(Observing { [weak self] in
            _ = NoteIndex.shared.version
            self?.renderSimilar()
        })
        observers.append(Observing { [weak self] in
            guard let self else { return }
            let time = self.player.isPlaying ? self.player.currentTime : nil
            if self.tab == .transcript { self.transcript.highlight(time: time) }
        })
        observers.append(Observing { [weak self] in
            // The recording was replaced by the joined one.
            guard let self else { return }
            _ = self.note.audioFileName
            self.player.stop()
            if let name = self.note.audioFileName, self.note.hasLocalAudio { self.player.load(AudioStore.url(for: name)) }
            self.fetchAudioError = nil
            self.fetchRecordingIfNeeded()
        })
        NotificationCenter.default.addObserver(self, selector: #selector(stopRecordingRequested), name: .porridgeStopRecording, object: nil)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        chips.hostWindow = view.window
        guard startsRecording else { return }
        // A new note that should record right away (Settings: "Record new notes").
        guard AVCaptureDevice.authorizationStatus(for: .audio) != .denied else { return }
        state.draftStartsRecording = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if self.dictation.phase == .idle { await self.toggleDictation() }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        player.stop()
        if dictation.phase == .recording { Task { await finishDictation() } }
        flushEditing()
    }

    override func removeFromParent() {
        flushEditing()
        observers.cancelAll()
        library.stopObserving(libraryToken)
        playerBar.stopObserving()
        editor.stop()
        taskBar.stop()
        micTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        super.removeFromParent()
    }

    /// The last letters typed go to the note, and the note is stored.
    func flushEditing() {
        editor?.flush()
        if note.modelContext != nil { library.save() }
    }

    func focusTitle() {
        view.window?.makeFirstResponder(titleField)
    }

    // MARK: State of the note

    private var opensOnSummary: Bool { note.isRecording || note.isLink || note.isStored }
    /// In a bowl shared with me to view only: nothing of the entry can be changed here.
    private var isReadOnly: Bool { !note.isDeleted && BowlSharing.shared.isReadOnly(note) }
    /// Nothing can be changed: the note is in Recently Deleted, or in a bowl I may only see.
    private var isLocked: Bool { note.isDeleted || isReadOnly }
    private var isSummarizing: Bool { processing.summarizing.contains(note.id) }
    private var isEnhancing: Bool { processing.enhancing.contains(note.id) }
    private var stage: String? { processing.stages[note.id] }

    private var canSummarize: Bool {
        stage == nil && !(note.text.isEmpty && note.title.isEmpty && note.segments.isEmpty && (note.pageText ?? "").isEmpty)
    }

    private var canEnhance: Bool {
        stage == nil && !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A recording that is only on another device (not in iCloud) could not be joined with the new part.
    private var canContinueRecording: Bool {
        stage == nil && note.status == .ready && note.pendingAudioFileName == nil && (note.audioFileName == nil || note.hasAudio)
    }

    private func computeTabs() -> [(NoteTab, String)] {
        var list: [(NoteTab, String)] = []
        if opensOnSummary { list.append((.summary, "Summary")) }
        // The tab stays while it is open, even when its text was just cleared.
        if !opensOnSummary || !note.text.isEmpty || tab == .note { list.append((.note, "Note")) }
        if note.isRecording { list.append((.transcript, "Transcript")) }
        if note.isLink {
            list.append((.article, "Article"))
        } else if note.attachmentsData != nil, !(note.pageText ?? "").isEmpty {
            list.append((.article, "Text"))
        }
        if !opensOnSummary, note.summary != nil || isSummarizing || tab == .summary { list.append((.summary, "Summary")) }
        return list
    }

    // MARK: Rendering

    private func render() {
        let note = note
        let isTodo = TodoBridge.isTodo(note)
        let isDone = TodoBridge.isDone(note)

        // Head
        todoBox.isHidden = !isTodo
        todoBox.isDone = isDone
        todoBox.isEnabled = !isLocked
        titleField.placeholderString = isTodo ? "To-do" : "Title"
        if titleField.currentEditor() == nil, titleField.stringValue != note.title { titleField.stringValue = note.title }
        titleField.isEditable = !isLocked
        titleField.textColor = isDone ? .secondaryLabelColor : .brandNavy
        if let source = TodoBridge.source(of: note) {
            sourcePill.isHidden = false
            sourcePill.title = source.displayTitle
            sourcePill.image = .symbol(source.kindSymbol, size: 11, weight: .semibold)
            sourcePill.setAccessibilityLabel("From \(source.displayTitle)")
        } else {
            sourcePill.isHidden = true
        }
        if let domain = note.domain, note.linkURL != nil {
            linkButton.isHidden = false
            linkButton.image = .symbol("link", size: 12, weight: .semibold)
            linkButton.attributedTitle = NSAttributedString(string: domain + "  ↗", attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), .foregroundColor: NSColor.brandLinkText,
            ])
            linkButton.setAccessibilityLabel("Open \(domain)")
        } else {
            linkButton.isHidden = true
        }
        meta.stringValue = metaLine(isTodo: isTodo, isDone: isDone)
        deletedBanner.isHidden = !note.isDeleted
        readOnlyBanner.isHidden = !isReadOnly
        activityLabel.stringValue = openedActivity ?? ""
        activityLabel.isHidden = openedActivity == nil || note.isDeleted
        chips.show(note, library: library)
        // Images shown in the note's text are not listed again.
        let listed = note.attachmentsData == nil ? [] : note.stripAttachments
        attachments.isHidden = listed.isEmpty
        if !listed.isEmpty { attachments.show(listed, canRemove: !isLocked) }
        renderStatus()
        renderSpeakers()
        let canUndo = processing.canUndoEnhance(note)
        enhancedBanner.isHidden = !(tab == .note && canUndo && dictation.phase == .idle)
        if canUndo {
            enhancedBanner.show(symbol: "wand.and.stars", text: "Enhanced with AI", tint: .brandSky, action: ("Undo", { [weak self] in
                self?.perform(.undoEnhance)
            }))
        }

        splitBanner.isHidden = lastSplit == nil
        if let lastSplit {
            splitBanner.show(symbol: "folder.badge.plus", text: lastSplit.summary, tint: .brandProject, action: ("Undo", { [weak self] in
                guard let self, let change = self.lastSplit else { return }
                self.lastSplit = nil
                BowlMaking.undo(change, in: self.library.context)
                self.library.setNeedsReload()
                self.render()
            }))
        }

        // Tabs
        let list = computeTabs()
        if !list.contains(where: { $0.0 == tab }), let first = list.first { tab = first.0 }
        if list.map(\.0) != tabOrder {
            tabOrder = list.map(\.0)
            tabs.segmentCount = list.count
            for (index, entry) in list.enumerated() {
                tabs.setLabel(entry.1, forSegment: index)
                tabs.setWidth(0, forSegment: index)
            }
        }
        tabs.isHidden = list.count < 2
        if let index = tabOrder.firstIndex(of: tab) { tabs.selectedSegment = index }

        // Content of the tab
        let dictating = dictation.phase != .idle
        editor.isHidden = tab != .note || dictating
        dictationPreviewScroll.isHidden = tab != .note || !dictating
        dictationStatus.isHidden = tab != .note || !dictating
        summaryScroll.isHidden = tab != .summary
        transcript.isHidden = tab != .transcript
        articleScroll.isHidden = true
        articleMessage.isHidden = true
        editor.isEditable = !isLocked && !isEnhancing
        editor.placeholderText = isTodo ? "Notes and subtasks…" : "Start typing or dictate…"
        addSubtask.isHidden = !(isTodo && !isLocked && !isEnhancing && EditorCommands.available)
        editor.reloadIfChanged()
        if dictating { renderDictationPreview() }

        switch tab {
        case .summary: renderSummary()
        case .transcript:
            transcript.canAssign = !isLocked
            transcript.show(
                note.segments, speakers: note.speakers,
                emptyMessage: note.status == .ready ? "No speech was detected." : "The transcript appears here once processing is done.",
                canPlay: note.hasLocalAudio
            )
        case .article: renderArticle()
        case .note: break
        }

        // Bottom
        playerBar.isHidden = !(note.hasLocalAudio && tab != .note)
        fetchBar.isHidden = !(!note.hasLocalAudio && (isFetchingAudio || fetchAudioError != nil || note.canFetchAudio) && tab != .note)
        fetchButton.isEnabled = !isFetchingAudio
        fetchButton.title = isFetchingAudio ? "Downloading Recording…" : "Download Recording"
        fetchMessage.stringValue = fetchAudioError ?? ""
        fetchMessage.isHidden = fetchAudioError == nil
        renderMic()

        showErrors()
        (view.window?.windowController as? NoteWindowController)?.window?.title = note.displayTitle
    }

    private func renderEntryLinks() {
        guard !note.isDeleted, note.modelContext != nil else {
            entryLinks.show(linkedFrom: [], mentions: [], target: nil)
            return
        }
        let notes = library.notes
        entryLinks.show(
            linkedFrom: EntryLinks.backlinks(to: note.id, among: notes),
            mentions: EntryLinks.mentions(of: note, among: notes),
            target: note
        )
    }

    private func renderSimilar() {
        guard !note.isDeleted, note.modelContext != nil else {
            similar.show([])
            return
        }
        similar.show(SimilarEntries.similar(to: note, among: library.notes))
    }

    private func metaLine(isTodo: Bool, isDone: Bool) -> String {
        var parts = [note.createdAt.formatted(.dateTime.weekday(.wide).day().month().hour().minute())]
        if note.isRecording, note.duration > 0 { parts.append(note.duration.durationText) }
        if let input = note.inputName { parts.append(input) }
        if isDone, let done = TodoBridge.doneAt(note) {
            parts.append(String(localized: "Done \(done.formatted(.dateTime.day().month(.abbreviated).hour().minute()))"))
        }
        let progress = TodoBridge.progress(of: note)
        if isTodo, progress.total > 0 { parts.append(String(localized: "\(progress.done) of \(progress.total) done")) }
        return parts.joined(separator: " · ")
    }

    private func renderStatus() {
        if let stage, !isSummarizing {
            var detail: String?
            if case .downloading(let progress) = ModelManager.shared.asr {
                detail = "Downloading Parakeet v3 (one time) – \(Int(progress * 100)) %"
            }
            statusPanel.show(symbol: nil, spinning: true, text: stage, detail: detail, tint: .brandSky, action: nil)
            statusPanel.isHidden = false
        } else if note.status == .ready, note.isRecording, let message = note.errorMessage, note.speakerMode == .none {
            statusPanel.show(symbol: "person.2.slash", text: message, tint: .systemGray, action: note.hasAudio ? ("Detect Speakers Again", { [weak self] in
                guard let self else { return }
                self.processing.enqueue(.transcript(self.note.id))
            }) : nil)
            statusPanel.isHidden = false
        } else if note.status == .failed {
            var retry: (() -> Void)?
            let note = note
            let processing = processing
            if note.isLink {
                retry = { note.status = .recorded; processing.enqueue(.link(note.id, summarize: false)) }
            } else if note.attachmentsData != nil, !note.isRecording {
                retry = { processing.enqueue(.attachment(note.id)) }
            } else if AudioStore.exists(note.pendingAudioFileName) {
                retry = { processing.enqueue(.note(note.id)) }
            } else if note.hasAudio {
                retry = { processing.enqueue(.transcript(note.id)) }
            }
            statusPanel.show(symbol: "exclamationmark.triangle.fill", text: note.errorMessage ?? "Transcription failed", tint: .systemRed, action: retry.map { ("Try Again", $0) })
            statusPanel.isHidden = false
        } else {
            statusPanel.isHidden = true
        }
    }

    private func renderSpeakers() {
        let list = note.speakers
        speakers.isHidden = list.isEmpty
        guard !list.isEmpty else { speakers.setViews([]); return }
        speakers.setViews(list.map { speaker in
            let title = AppSettings.isMe(speaker) ? "\(speaker.name) (Me)" : speaker.name
            let pill = PillButton(title: title, symbol: "pencil", tint: .speaker(speaker.colorIndex), target: self, action: #selector(renameSpeaker(_:)))
            pill.identifier = .init(speaker.id)
            pill.isEnabled = !isLocked
            pill.setAccessibilityLabel("Rename \(speaker.name)")
            return pill
        })
    }

    private var summarizeMessage: String {
        note.isRecording
            ? "Let AI summarize this meeting – including decisions and action items."
            : note.isLink ? "Let AI summarize this page." : note.isImage ? "Let AI summarize this image." : note.isFile ? "Let AI summarize this file." : "Let AI summarize this note."
    }

    private func renderSummary() {
        let summarizingNow = isSummarizing
        summarizing.isHidden = !summarizingNow
        if summarizingNow {
            summarizingMessage.stringValue = summarizeMessage
            summarizingDetail.stringValue = [stage, processing.summaryModels[note.id]?.label ?? SummaryService.modelLabel].compactMap { $0 }.joined(separator: "\n")
        }
        let summary = summarizingNow ? nil : note.summary
        if summary == nil {
            suggestedTodos.isHidden = true
            madeTodos.isHidden = true
        }
        summaryText.superview?.isHidden = summary == nil
        summaryModelLabel.isHidden = summary == nil || note.summaryModel == nil
        summaryEmpty.isHidden = summarizingNow || summary != nil
        if let summary {
            let interactive = !(isLocked || note.isSaved)
            summaryText.onToggleTask = interactive ? { [weak self] line in
                guard let self else { return }
                SummaryTasks.toggleLine(line, of: self.note, in: self.library.context)
            } : nil
            // The tasks of the summary offered as to-dos, and what became of them; never from a saved page or file.
            let made = TodoBridge.madeFrom(note)
            let states = TodoSuggestions.states(note.todoSuggestionsRaw)
            summaryText.isTakenTask = note.isSaved ? nil : { text in
                TodoSuggestions.isTaken(text, states: states, madeTitles: made.map(\.title))
            }
            let pending = isLocked ? [] : note.pendingTodoSuggestions(made: made)
            suggestedTodos.isHidden = pending.isEmpty
            if !pending.isEmpty { suggestedTodos.show(pending, of: note) }
            madeTodos.isHidden = made.isEmpty
            if !made.isEmpty { madeTodos.show(made) }
            summaryText.show(summary)
            summaryMenuButton.isHidden = isLocked
            summaryModelLabel.stringValue = note.summaryModel.map { "Created with \($0)" } ?? ""
        } else {
            summaryEmptyMessage.stringValue = summarizeMessage
            summarizeButton.isHidden = isLocked
            summarizeButton.isEnabled = canSummarize
        }
    }

    private func renderArticle() {
        if let text = note.pageText, !text.isEmpty {
            articleScroll.isHidden = false
            if articleText.string != text { articleText.string = text }
        } else {
            articleMessage.isHidden = false
            if (stage != nil && !isSummarizing) || note.pageText == nil, note.status != .failed {
                articleMessage.stringValue = "The text of the page appears here once it is loaded."
            } else if note.status != .failed {
                articleMessage.stringValue = "There is no readable text on this page." + (note.linkURL != nil ? " Open it in the browser with the link above." : "")
            } else {
                articleMessage.stringValue = ""
            }
        }
    }

    private func renderMic() {
        let shows = tab == .note && stage == nil && !isLocked
        micButton.isHidden = !shows
        micButton.phase = dictation.phase
        micTime.isHidden = !(shows && dictation.phase == .recording)
        if dictation.phase == .recording {
            if micTimer == nil {
                micTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.micTime.stringValue = self.dictation.recorder.elapsed.clockString
                        self.micButton.level = CGFloat(self.dictation.recorder.levels.max() ?? 0)
                    }
                }
            }
        } else {
            micTimer?.invalidate()
            micTimer = nil
            micButton.level = 0
        }
        // What the dictation is doing, above its preview.
        switch dictation.phase {
        case .polishing:
            dictationStatus.stringValue = "Polishing…"
        case .recording:
            if case .downloading = ModelManager.shared.asr {
                dictationStatus.stringValue = "Downloading speech model…"
            } else {
                switch dictation.live.phase {
                case .idle, .preparing, .downloading: dictationStatus.stringValue = "Starting…"
                case .running: dictationStatus.stringValue = "Listening…"
                case .unavailable: dictationStatus.stringValue = "No live preview – the text appears when you stop"
                }
            }
        case .idle:
            dictationStatus.stringValue = ""
        }
    }

    /// The note while dictating: the live text in the accent color where it will go.
    private func renderDictationPreview() {
        let text = note.text
        let split = text.index(text.startIndex, offsetBy: min(dictationStart, text.count))
        let before = String(text[..<split])
        let after = String(text[split...])
        let live = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = !live.isEmpty && !before.isEmpty && before.last?.isWhitespace == false ? " " : ""
        let font = NSFont.preferredFont(forTextStyle: .body)
        let result = NSMutableAttributedString(string: before, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        result.append(NSAttributedString(string: lead + live, attributes: [.font: font, .foregroundColor: NSColor.controlAccentColor]))
        result.append(NSAttributedString(string: "▍", attributes: [.font: font, .foregroundColor: NSColor.controlAccentColor]))
        result.append(NSAttributedString(string: after, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        dictationPreview.textStorage?.setAttributedString(result)
        dictationPreview.scrollToEndOfDocument(nil)
    }

    /// Errors of the queue and the dictation, each told once.
    private func showErrors() {
        if let error = processing.summaryErrors[note.id], !shownErrors.contains("summary" + error) {
            shownErrors.insert("summary" + error)
            Alerts.inform("Summary Failed", message: error, in: view.window)
            processing.clearSummaryError(note.id)
        }
        if let error = processing.enhanceErrors[note.id], !shownErrors.contains("enhance" + error) {
            shownErrors.insert("enhance" + error)
            Alerts.inform("Enhance Failed", message: error, in: view.window)
            processing.clearEnhanceError(note.id)
        }
        if let error = dictation.errorMessage, dictation.phase == .idle {
            Alerts.inform("Can't Dictate", message: error, in: view.window)
            dictation.dismissError()
        }
    }

    // MARK: Editing

    private func setText(_ text: String) {
        let old = note.text
        guard text != old else { return }
        note.text = text
        note.updatedAt = Date()
        // A box ticked in the editor, a subtask added: the to-do follows.
        TodoBridge.follow(note, from: old)
        saveIfFilled()
        taskBar.schedule(for: note)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === titleField else { return }
        note.title = titleField.stringValue
        note.titleIsCustom = true
        note.updatedAt = Date()
        saveIfFilled()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Return in the title goes on in the text.
        if control === titleField, commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if tab == .note, !editor.isHidden { editor.focus() } else { view.window?.makeFirstResponder(nil) }
            return true
        }
        return false
    }

    /// Stores a new note the first time it has a title or text.
    private func saveIfFilled() {
        guard note.modelContext == nil, !(note.text.isEmpty && note.title.isEmpty) else { return }
        library.context.insert(note)
        library.save()
    }

    private func addTag() {
        Alerts.ask("New Tag", placeholder: "Tag", action: "Add", in: view.window) { [weak self] text in
            guard let self else { return }
            let tag = Note.cleanTag(text)
            guard !tag.isEmpty, !self.note.tags.contains(where: { $0.lowercased() == tag.lowercased() }) else { return }
            self.note.labels.append(tag)
            self.saveIfFilled()
            self.library.save()
        }
    }

    /// Takes a file off the note and deletes it, here and in iCloud.
    private func removeAttachment(_ attachment: Attachment) {
        note.removeAttachment(id: attachment.id)
        AudioStore.delete(attachment.fileName)
        note.updatedAt = Date()
        if note.attachments.isEmpty {
            if !note.isLink { note.pageText = nil }
        } else {
            processing.enqueue(.attachment(note.id))
        }
        library.save()
    }

    /// A meeting recorded for an appointment offers its people as names in a menu, one click each; otherwise (and
    /// with "Other Name…") the name is typed.
    @objc private func renameSpeaker(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let speaker = note.speakers.first(where: { $0.id == id }) else { return }
        let choices = SpeakerNaming.choices(for: id, in: note)
        guard !choices.isEmpty else {
            askSpeakerName(speaker)
            return
        }
        let menu = NSMenu()
        menu.addItem(.sectionHeader(title: String(localized: "Invited")))
        for name in choices {
            menu.add(name) { [weak self] in self?.nameSpeaker(id, name) }
        }
        menu.addItem(.separator())
        menu.add(String(localized: "Other Name…"), symbol: "pencil") { [weak self] in self?.askSpeakerName(speaker) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func askSpeakerName(_ speaker: Speaker) {
        Alerts.ask("Rename Speaker", placeholder: "Name", value: speaker.name, action: "Save", in: view.window) { [weak self] text in
            self?.nameSpeaker(speaker.id, text)
        }
    }

    /// Also teaches the voice under this name, checks earlier unnamed speakers against it and writes the summary
    /// again with it (`SpeakerNaming.rename`).
    private func nameSpeaker(_ id: String, _ name: String) {
        SpeakerNaming.rename(id, to: name, in: note, context: library.context, processing: processing)
        library.setNeedsReload()
    }

    private func reassign(_ segment: TranscriptSegment, to speaker: Speaker) {
        note.segments = note.segments.map { item in
            var item = item
            if item.id == segment.id { item.speakerId = speaker.id }
            return item
        }
        library.save()
    }

    @objc private func toggleDone() {
        // What the box showed when it was clicked, before the typing that is handed over now moves it.
        let done = !TodoBridge.isDone(note)
        // A commit still pending would otherwise write the unticked subtasks back over "done".
        editor.flush()
        TodoBridge.setDone(done, note)
    }

    @objc private func openSource() {
        guard let source = TodoBridge.source(of: note) else { return }
        state.reveal(source)
    }

    @objc private func openLink() {
        if let url = note.linkURL { NSWorkspace.shared.open(url) }
    }

    @objc private func tabChosen() {
        guard tabs.selectedSegment >= 0, tabs.selectedSegment < tabOrder.count else { return }
        show(tabOrder[tabs.selectedSegment])
    }

    private func show(_ next: NoteTab) {
        guard computeTabs().contains(where: { $0.0 == next }) || next == .summary || next == .note else { return }
        if tab == .note { editor.flush() }
        tab = next
        didChooseTab = true
        render()
    }

    private func recover() {
        NoteStore.restore(note, in: library.context)
        state.selection.removeAll { $0 == note.id }
    }

    @objc private func requestSummaryAction() { perform(.summarize) }

    @objc private func stopRecordingRequested() {
        if dictation.phase == .recording { Task { await finishDictation() } }
    }

    // MARK: Recording

    private func confirmDeleteRecording() {
        Alerts.confirm(
            "Delete Recording?",
            message: AudioStore.deleteRecordingMessage,
            action: "Delete Recording", in: view.window
        ) { [weak self] in
            guard let self else { return }
            self.player.stop()
            AudioStore.delete(self.note.audioFileName)
            self.note.audioFileName = nil
            self.library.save()
        }
    }

    /// Downloads the recording when it is in iCloud and not here yet (after the container was found at launch).
    private func fetchRecordingIfNeeded() {
        guard fetchTask == nil, note.audioFileName != nil, !note.hasLocalAudio else { return }
        fetchTask = Task { @MainActor [weak self] in
            _ = await AudioStore.cloudContainer()
            guard let self else { return }
            self.fetchTask = nil
            if let name = self.note.audioFileName, self.note.hasLocalAudio {
                self.player.load(AudioStore.url(for: name))
                self.render()
            } else if self.note.canFetchAudio, self.fetchAudioError == nil {
                self.fetchRecording()
            } else {
                self.render()
            }
        }
    }

    @objc private func fetchRecording() {
        guard let name = note.audioFileName, !isFetchingAudio else { return }
        isFetchingAudio = true
        fetchAudioError = nil
        render()
        Task { @MainActor [weak self] in
            var failure: String?
            do {
                try await AudioStore.download(name)
            } catch {
                failure = error.localizedDescription
            }
            guard let self else { return }
            self.isFetchingAudio = false
            self.fetchAudioError = failure
            if failure == nil, self.note.audioFileName == name { self.player.load(AudioStore.url(for: name)) }
            self.render()
        }
    }

    // MARK: Dictation

    @objc private func toggleDictationAction() {
        Task { await toggleDictation() }
    }

    private func toggleDictation() async {
        switch dictation.phase {
        case .idle:
            // The text appears where the cursor was.
            if tab != .note { tab = .note }
            editor.flush()
            dictationStart = editor.controller.cursorOffset
            liveText = ""
            view.window?.makeFirstResponder(nil)
            await dictation.start(title: note.title.isEmpty ? "Note" : note.title)
            render()
        case .recording:
            await finishDictation()
        case .polishing:
            break
        }
    }

    /// Stops recording and puts the final transcript of the whole recording into the note.
    private func finishDictation() async {
        guard let result = await dictation.stop() else { return }
        insertDictated(result.text)
        if let fileName = result.fileName {
            if note.text.isEmpty, note.title.isEmpty {
                // Nothing was recognized: no note, so no recording to keep either.
                AudioStore.delete(fileName)
            } else {
                note.audioFileNames.append(fileName)
            }
        }
        liveText = ""
        saveIfFilled()
        if note.modelContext != nil { library.save() }
        render()
    }

    /// Inserts the dictated text where the dictation started.
    private func insertDictated(_ dictated: String) {
        var text = note.text
        let index = text.index(text.startIndex, offsetBy: min(dictationStart, text.count))
        var piece = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return }
        if index > text.startIndex, let before = text[..<index].last, !before.isWhitespace { piece = " " + piece }
        if index < text.endIndex, let after = text[index...].first, !after.isWhitespace { piece += " " }
        text.insert(contentsOf: piece, at: index)
        setText(text)
        editor.reloadIfChanged()
    }

    // MARK: Commands (menu bar, More menu)

    func perform(_ command: NoteCommand) {
        switch command {
        case .summarize:
            editor.flush()
            NoteSheets.summaryOptions(for: note, in: self)
        case .enhance:
            editor.flush()
            NoteSheets.enhanceOptions(for: note, in: self)
        case .undoEnhance:
            // Typing still on its way would otherwise be written over the original text afterwards. With it
            // handed over the text is no longer the enhanced one, and the undo rightly does nothing.
            editor.flush()
            processing.undoEnhance(note)
        case .editSummary:
            tab = .summary
            NoteSheets.editSummary(of: note, in: self)
        case .insertSummary:
            guard let summary = note.summary else { return }
            // The typing of the last moment first: a pending commit would drop the summary again.
            editor.flush()
            setText(note.text.isEmpty ? summary : note.text + "\n\n" + summary)
            editor.reloadIfChanged()
            library.save()
        case .copySummary:
            guard let summary = note.summary else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(summary, forType: .string)
        case .deleteSummary:
            Alerts.confirm("Delete Summary?", message: "Your edits and check marks in it are lost. You can write a new one at any time.", action: "Delete Summary", in: view.window) { [weak self] in
                guard let self else { return }
                SummaryService.removeSummary(self.note)
                self.library.save()
            }
        case .continueRecording:
            if note.summary == nil {
                NoteSheets.continueRecording(note, in: self)
            } else {
                Alerts.confirm("Continue Recording?", message: "The new part is added to the meeting. The summary is removed and can be written again.", action: "Continue", isDestructive: false, in: view.window) { [weak self] in
                    guard let self else { return }
                    NoteSheets.continueRecording(self.note, in: self)
                }
            }
        case .splitIntoBowl:
            editor.flush()
            presentAsSheet(SplitNoteViewController(note: note) { [weak self] change in
                guard let self else { return }
                self.lastSplit = change
                self.library.setNeedsReload()
                self.render()
                // The way back is offered for a while only.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: BowlMaking.undoLifetime)
                    guard let self, self.lastSplit?.madeAt == change.madeAt else { return }
                    self.lastSplit = nil
                    self.render()
                }
            })
        case .merge:
            NoteSheets.merge(note, in: self)
        case .export:
            if note.isRecording, !note.isLink {
                NoteSheets.export(note, in: self)
            } else {
                exportAsText()
            }
        case .deleteRecording:
            confirmDeleteRecording()
        case .loadPageAgain:
            guard note.isLink else { return }
            note.status = .recorded
            processing.enqueue(.link(note.id, summarize: false))
        case .dictate:
            toggleDictationAction()
        case .addTag:
            addTag()
        case .toggleTodo:
            toggleDone()
        case .convertTodo:
            TodoBridge.setTodo(!TodoBridge.isTodo(note), note)
        case .suggestTodos:
            // The tasks of the summary as to-dos again, dismissed ones included.
            TodoSuggestions.suggestAgain(note, in: library.context)
            show(.summary)
        case .showSummary: show(.summary)
        case .showNote: show(.note)
        case .showTranscript: show(.transcript)
        case .showArticle: show(.article)
        }
    }

    /// Whether a command applies now; sets the item's title where it depends on the note.
    func validate(_ command: NoteCommand, item: NSMenuItem) -> Bool {
        // Nothing changes on a note in Recently Deleted, or in a bowl shared with me to view only.
        let deleted = isLocked
        switch command {
        case .summarize:
            item.title = note.summary == nil ? "Summarize with AI…" : "Summarize Again with AI…"
            return !deleted && !isSummarizing && canSummarize
        case .enhance:
            return !deleted && !opensOnSummary && canEnhance
        case .undoEnhance:
            return !deleted && processing.canUndoEnhance(note)
        case .editSummary:
            return !deleted && !isSummarizing
        case .copySummary:
            return note.summary != nil && !note.isDeleted
        case .insertSummary:
            return note.summary != nil && !deleted
        case .deleteSummary:
            return note.summary != nil && !deleted
        case .continueRecording:
            return !deleted && note.isRecording && !note.isLink && canContinueRecording
        case .splitIntoBowl:
            return !deleted && stage == nil && NoteSplitter.canSplit(note)
        case .merge:
            return !deleted && !note.segments.isEmpty && stage == nil && note.status == .ready
        case .export:
            return true
        case .deleteRecording:
            return !deleted && note.hasAudio
        case .loadPageAgain:
            return !deleted && note.isLink && stage == nil
        case .dictate:
            item.title = dictation.phase == .recording ? "Stop Dictation" : "Dictate"
            return !deleted && stage == nil && dictation.phase != .polishing
        case .addTag:
            return !deleted
        case .toggleTodo:
            item.title = TodoBridge.isDone(note) ? "Mark as Not Done" : "Mark as Done"
            item.isHidden = !TodoBridge.isTodo(note)
            return !deleted && TodoBridge.isTodo(note)
        case .convertTodo:
            item.title = TodoBridge.isTodo(note) ? "Convert to Note" : "Convert to To-do"
            item.isHidden = !TodoBridge.available
            return !deleted && TodoBridge.canBeTodo(note)
        case .suggestTodos:
            return !deleted && note.summary != nil && !note.isSaved && !note.isTodo && !isSummarizing
        case .showSummary: return computeTabs().contains { $0.0 == .summary }
        case .showNote: return computeTabs().contains { $0.0 == .note }
        case .showTranscript: return computeTabs().contains { $0.0 == .transcript }
        case .showArticle: return computeTabs().contains { $0.0 == .article }
        }
    }

    /// Notes, links and files leave as a text file.
    private func exportAsText() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (note.displayTitle.isEmpty ? "Note" : note.displayTitle) + ".md"
        panel.allowedContentTypes = [.plainText]
        guard let window = view.window else { return }
        let text = note.exportText
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    #if DEBUG
    func debugSuggestions(_ command: String) {
        suggestedTodos.debug(command)
    }

    func debugType(title: String? = nil, body: String? = nil) {
        if let title {
            titleField.stringValue = title
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: titleField))
        }
        if let body {
            editor.flush()
            setText(note.text.isEmpty ? body : note.text + "\n" + body)
            editor.reloadIfChanged()
        }
    }
    #endif
}

/// A view whose origin is at the top, for documents of scroll views.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A flat panel with a symbol or a spinner, a line of text and maybe a button: the state of a note.
final class PanelView: NSView {
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let label = NSTextField.label(font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), lines: 0)
    private let detail = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, lines: 2)
    private let button = ActionButton(title: "") {}
    private var tint: NSColor = .brandSky

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView.vertical([label, detail], spacing: 2)
        let row = NSStackView.horizontal([icon, spinner, text, NSView(), button], spacing: 10)
        addSubview(row)
        row.pinEdges(to: self, insets: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = tint.withAlphaComponent(0.12).resolved(for: self)
    }

    func show(symbol: String?, spinning: Bool = false, text: String, detail: String? = nil, tint: NSColor, action: (String, () -> Void)?) {
        self.tint = tint
        icon.isHidden = symbol == nil
        if let symbol { icon.image = .symbol(symbol, size: 14, weight: .semibold) }
        icon.contentTintColor = tint.readable
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        label.stringValue = text
        label.textColor = tint == .systemRed ? .brandDangerText : .labelColor
        self.detail.stringValue = detail ?? ""
        self.detail.isHidden = detail == nil
        button.isHidden = action == nil
        if let action {
            button.title = action.0
            button.setHandler(action.1)
        }
        needsDisplay = true
        updateLayer()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel([text, detail].compactMap { $0 }.joined(separator: ", "))
    }
}

/// The round microphone of the note page: sky to dictate, red while recording (it grows with the voice), a
/// spinner while the text is polished.
final class MicButton: NSButton {
    var phase: InlineDictation.Phase = .idle { didSet { update() } }
    var level: CGFloat = 0 { didSet { needsDisplay = true } }
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 64).isActive = true
        heightAnchor.constraint(equalToConstant: 64).isActive = true
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        spinner.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        spinner.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        toolTip = phase == .recording ? "Stop Dictation" : "Dictate"
        setAccessibilityLabel(toolTip)
        isEnabled = phase != .polishing
        if phase == .polishing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let recording = phase == .recording
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        if recording {
            let halo = 24 * (1 + min(level, 1) * 0.35)
            NSColor.systemRed.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - halo, y: center.y - halo, width: halo * 2, height: halo * 2)).fill()
        }
        let radius: CGFloat = 23
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = (recording ? NSColor.systemRed : NSColor.brandSky).withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        (recording ? NSColor.systemRed : NSColor.brandSky).withAlphaComponent(isHighlighted ? 0.8 : 1).setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()
        guard phase != .polishing else { return }
        let symbol = NSImage.symbol(recording ? "stop.fill" : "mic.fill", size: 19, weight: .semibold).tinted(recording ? .white : .brandOnFill)
        symbol.draw(in: NSRect(x: center.x - symbol.size.width / 2, y: center.y - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height))
    }
}
