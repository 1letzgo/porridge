import AppKit

/// Where a meeting is recorded: in the right column of the main window it was started from (`MainSplitViewController`),
/// so the rest of the window stays usable; in a window of its own only when no main window is open (a global
/// shortcut, the last main window closed while recording). Only one recording at a time.
@MainActor
enum MeetingRecorder {
    struct Finished {
        let result: RecordingResult
        let speakerNames: [String]
        let liveText: String
        let written: [RecordingNote]
    }

    private static var current: RecordingViewController?
    private static weak var pane: MainWindowController?
    private static var window: RecordingWindow?

    /// A recording is running somewhere.
    static var isRecording: Bool { current != nil }

    /// Ends the running recording as Stop does, so the meeting is kept (before quitting).
    static func stopAll() {
        current?.stop()
    }

    /// Starts recording in the right column of `controller` (the front main window when nil). A recording that runs
    /// already comes to the front instead.
    static func start(title: String?, continues: UUID? = nil, in controller: MainWindowController? = nil, onFinish: @escaping (Finished) -> Void) {
        guard current == nil else {
            reveal()
            return
        }
        let recording = RecordingViewController(title: title, continues: continues, onFinish: onFinish)
        recording.onClose = { close() }
        current = recording
        host(recording, in: controller ?? MainWindowController.frontIfAny)
        Task { @MainActor in await recording.begin() }
    }

    /// Shows the running recording.
    static func reveal() {
        if let pane, let window = pane.window {
            pane.split.showMeetingPane(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            window?.showWindow(nil)
            window?.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// The main window that shows the recording is closing: the recording goes on in a window of its own.
    static func mainWindowWillClose(_ controller: MainWindowController) {
        guard let current, pane === controller else { return }
        controller.split.hideMeetingPane()
        pane = nil
        host(current, in: nil)
    }

    private static func host(_ recording: RecordingViewController, in controller: MainWindowController?) {
        if let controller {
            pane = controller
            controller.split.showMeetingPane(recording)
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            let window = RecordingWindow(recording)
            self.window = window
            window.showWindow(nil)
            window.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// The recording ended (stopped or discarded): its column closes, or its window.
    private static func close() {
        current?.tearDown()
        current = nil
        if let pane { pane.split.hideMeetingPane() }
        pane = nil
        let window = self.window
        self.window = nil
        window?.closeAfterRecording()
    }
}

/// The window of a recording when no main window shows it. Closing it asks whether to discard the recording.
final class RecordingWindow: NSWindowController, NSWindowDelegate {
    private let recording: RecordingViewController
    private var closing = false

    init(_ recording: RecordingViewController) {
        self.recording = recording
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = recording.meetingTitle.map { "Recording · \($0)" } ?? "Recording"
        window.minSize = NSSize(width: 360, height: 520)
        window.tabbingMode = .disallowed
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        recording.view.removeFromSuperview()
        recording.removeFromParent()
        window.contentViewController = recording
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func closeAfterRecording() {
        closing = true
        close()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing { return true }
        recording.confirmDiscard()
        return false
    }
}

/// A meeting being recorded: the clock, the levels (two named speakers on a split stereo microphone, or the user and
/// the others when the Mac's sound is recorded too, see `SystemAudioTap`), the live transcript, notes typed along
/// the way, pause and stop. Shown by `MeetingRecorder`.
final class RecordingViewController: NSViewController, NSTextFieldDelegate {
    typealias Finished = MeetingRecorder.Finished

    /// Called once the recording ended (stopped or discarded).
    var onClose: (() -> Void)?

    let meetingTitle: String?
    private let continues: UUID?
    private let onFinish: (Finished) -> Void
    private let recorder = AudioRecorder()
    private let live = LiveTranscriber()
    private var journal: RecordingJournal?
    private var notes: [RecordingNote] = []
    private var finished = false
    private var observers: [Observing] = []
    private var timer: Timer?

    private let inputLabel = NSTextField.label(font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), color: .controlAccentColor)
    private let clock = NSTextField.label(font: .monospacedDigitSystemFont(ofSize: 54, weight: .bold))
    private let meter = LevelBarView()
    private let stereo = NSStackView()
    private let nameFields = [NSTextField(string: "Speaker 1"), NSTextField(string: "Speaker 2")]
    private let stereoMeters = [LevelBarView(), LevelBarView()]
    private let transcript = NSTextView()
    private let notesList = NSStackView()
    private let noteField = NSTextField()
    private let hint = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, lines: 0)
    private let pauseButton = NSButton()
    private let stopButton = NSButton()

    private let heading = NSTextField.label(font: .systemFont(ofSize: 17, weight: .bold), lines: 2)

    init(title: String?, continues: UUID?, onFinish: @escaping (Finished) -> Void) {
        meetingTitle = title
        self.continues = continues
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
        self.title = title.map { "Recording · \($0)" } ?? "Recording"
        // Meetings only: the Mac's sound on the right channel, the microphone (the user) on the left.
        if MeetingAudio.includesSystemAudio {
            recorder.secondChannel = SystemAudioTap()
            nameFields[0].stringValue = AppSettings.myName ?? "Me"
            nameFields[1].stringValue = SystemAudioMix.othersName
        }
    }

    override func loadView() {
        view = buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Building

    private func buildContent() -> NSView {
        let root = NSView()
        heading.stringValue = meetingTitle ?? String(localized: "Recording")
        hint.lineBreakMode = .byWordWrapping
        heading.alignment = .center
        clock.alignment = .center
        clock.setAccessibilityLabel("Elapsed Time")

        stereo.orientation = .vertical
        stereo.spacing = 8
        for index in 0..<2 {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 6
            dot.layer?.backgroundColor = NSColor.speaker(index).cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 12).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 12).isActive = true
            let field = nameFields[index]
            field.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
            field.placeholderString = "Name"
            field.setAccessibilityLabel("Name of Speaker \(index + 1)")
            let meter = stereoMeters[index]
            meter.widthAnchor.constraint(equalToConstant: 120).isActive = true
            stereo.addArrangedSubview(NSStackView.horizontal([dot, field, meter], spacing: 10))
        }
        stereo.isHidden = true

        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.textContainerInset = NSSize(width: 12, height: 12)
        transcript.isVerticallyResizable = true
        transcript.autoresizingMask = [.width]
        transcript.setAccessibilityLabel("Live Transcript")
        let transcriptScroll = NSScrollView()
        transcriptScroll.documentView = transcript
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.borderType = .noBorder
        transcriptScroll.drawsBackground = true
        transcriptScroll.backgroundColor = .controlBackgroundColor
        transcriptScroll.wantsLayer = true
        transcriptScroll.layer?.cornerRadius = 12
        transcriptScroll.translatesAutoresizingMaskIntoConstraints = false

        notesList.orientation = .vertical
        notesList.alignment = .trailing
        notesList.spacing = 6
        noteField.placeholderString = "Add a note…"
        noteField.delegate = self
        noteField.target = self
        noteField.action = #selector(addNote)
        noteField.setAccessibilityLabel("Note")
        let addButton = NSButton(image: .symbol("arrow.up.circle.fill", size: 20, weight: .semibold, label: "Add Note"), target: self, action: #selector(addNote))
        addButton.isBordered = false
        addButton.contentTintColor = .brandSky
        addButton.toolTip = "Add Note"
        let noteRow = NSStackView.horizontal([noteField, addButton], spacing: 8)

        pauseButton.bezelStyle = .circular
        pauseButton.controlSize = .large
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.contentTintColor = .controlAccentColor
        stopButton.bezelStyle = .push
        stopButton.controlSize = .large
        stopButton.title = "Stop"
        stopButton.image = .symbol("stop.fill", size: 13, weight: .bold)
        stopButton.imagePosition = .imageLeading
        stopButton.contentTintColor = .systemRed
        stopButton.target = self
        stopButton.action = #selector(stop)
        stopButton.setAccessibilityLabel("Stop Recording")
        let discard = ActionButton(title: "Discard…") { [weak self] in self?.confirmDiscard() }
        let buttons = NSStackView.horizontal([discard, NSView(), pauseButton, stopButton], spacing: 12)

        let stack = NSStackView.vertical([heading, inputLabel, clock, meter, stereo, transcriptScroll, notesList, noteRow, hint, buttons], spacing: 14, alignment: .centerX)
        root.addSubview(stack)
        stack.pinEdges(to: root, insets: NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20))
        NSLayoutConstraint.activate([
            meter.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.7),
            heading.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            meter.heightAnchor.constraint(equalToConstant: 12),
            transcriptScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            transcriptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            notesList.widthAnchor.constraint(equalTo: stack.widthAnchor),
            noteRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hint.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        transcriptScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        return root
    }

    // MARK: Recording

    func begin() async {
        guard await AudioRecorder.requestPermission() else {
            fail("Please allow microphone access in System Settings, under Privacy & Security.")
            return
        }
        guard !recorder.isRecording, !finished else { return }
        recorder.onInterrupted = { [weak self] in self?.stop() }
        recorder.pausesForCalls = true
        recorder.onPauseChanged = { [weak self] in
            guard let self else { return }
            LiveRecording.setPaused(self.recorder.isPaused, elapsed: self.recorder.elapsed)
        }
        do {
            let journal = RecordingJournal(title: meetingTitle, continues: continues)
            self.journal = journal
            let feed = live.feed
            recorder.onBuffer = { buffer in
                feed(buffer)
                journal.append(buffer)
            }
            try recorder.start()
            journal.setUnfinishedFile(recorder.fileName)
            LiveRecording.start(kind: .meeting, title: "Meeting", onTogglePause: { [weak self] in self?.togglePause() }) { [weak self] in self?.stop() }
            observers.append(Observing { [weak self] in self?.render() })
            observers.append(Observing { [weak self] in
                guard let self else { return }
                self.live.observeDownload(ModelManager.shared.asr)
            })
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            NotificationCenter.default.addObserver(self, selector: #selector(stop), name: .porridgeStopRecording, object: nil)
            await live.start(language: AppSettings.language)
        } catch {
            journal?.finish()
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        finished = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Can't Record"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window) { [weak self] _ in self?.onClose?() }
        } else {
            alert.runModal()
            onClose?()
        }
    }

    private func tick() {
        clock.stringValue = recorder.elapsed.clockString
        clock.textColor = recorder.isPaused ? .secondaryLabelColor : .labelColor
        meter.level = CGFloat(recorder.levels.max() ?? 0)
        for index in 0..<2 {
            stereoMeters[index].level = CGFloat(index < recorder.levels.count ? recorder.levels[index] : 0)
        }
    }

    private func render() {
        let input = recorder.inputName.isEmpty ? "Microphone"
            : (recorder.isSplitStereo && !recorder.includesSystemAudio ? "\(recorder.inputName) · 2 channels" : recorder.inputName)
        inputLabel.stringValue = recorder.isPausedForCall ? "Paused for Call" : recorder.isPaused ? "Paused" : input
        stereo.isHidden = !recorder.isSplitStereo
        meter.isHidden = recorder.isSplitStereo
        if recorder.includesSystemAudio {
            hint.stringValue = "Your microphone is you, the Mac's sound is the others. If their bar stays still while they talk, allow Porridge in System Settings under Privacy & Security, Screen & System Audio Recording."
        } else if let error = recorder.secondChannelError {
            hint.stringValue = "\(error) Recording the microphone only."
        } else if recorder.isSplitStereo {
            hint.stringValue = "Each microphone is assigned to one speaker. You can rename them now or later."
        } else if recorder.isExternal, recorder.inputName.localizedCaseInsensitiveContains("DJI") {
            hint.stringValue = "Tip: switch your DJI receiver to stereo to separate speakers per microphone."
        } else {
            hint.stringValue = ""
        }
        hint.isHidden = hint.stringValue.isEmpty
        pauseButton.image = .symbol(recorder.isPaused ? "play.fill" : "pause.fill", size: 15, weight: .bold, label: recorder.isPaused ? "Resume Recording" : "Pause Recording")
        pauseButton.toolTip = recorder.isPaused ? "Resume Recording" : "Pause Recording"
        pauseButton.isEnabled = recorder.isRecording && !recorder.isPausedForCall
        stopButton.isEnabled = recorder.isRecording
        renderTranscript()
    }

    /// The running text in short paragraphs; what is not confirmed yet is dimmed.
    private func renderTranscript() {
        let font = NSFont.preferredFont(forTextStyle: .body)
        let result = NSMutableAttributedString()
        switch live.phase {
        case .idle, .preparing:
            result.append(NSAttributedString(string: "Starting live transcription…", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        case .downloading(let progress):
            result.append(NSAttributedString(string: "Downloading speech model (one time)… \(Int(progress * 100)) %", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        case .unavailable:
            result.append(NSAttributedString(string: "Live transcription unavailable. The transcript is created after recording.", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        case .running:
            if live.text.isEmpty {
                result.append(NSAttributedString(string: recorder.isPaused ? "Paused" : "Listening…", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            } else {
                let confirmedCount = Paragraphs.sentences(live.confirmed).count
                let all = Paragraphs.sentences([live.confirmed, live.volatile].filter { !$0.isEmpty }.joined(separator: " "))
                let groups = Paragraphs.group(all.enumerated().map { (text: $0.element, flag: $0.offset >= confirmedCount) })
                for (index, group) in groups.enumerated() {
                    if index > 0 { result.append(NSAttributedString(string: "\n\n", attributes: [.font: font])) }
                    for (offset, item) in group.enumerated() {
                        result.append(NSAttributedString(string: (offset == 0 ? "" : " ") + item.text, attributes: [
                            .font: font, .foregroundColor: item.flag ? NSColor.secondaryLabelColor : NSColor.labelColor,
                        ]))
                    }
                }
            }
        }
        transcript.textStorage?.setAttributedString(result)
        transcript.scrollToEndOfDocument(nil)
    }

    @objc private func togglePause() {
        // It goes on by itself when the call ends.
        guard !recorder.isPausedForCall else { return }
        if recorder.isPaused { recorder.resume() } else { recorder.pause() }
        LiveRecording.setPaused(recorder.isPaused, elapsed: recorder.elapsed)
    }

    @objc private func addNote() {
        let text = noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, recorder.isRecording else { return }
        let note = RecordingNote(at: recorder.elapsed, text: text)
        notes.append(note)
        journal?.setNotes(notes)
        noteField.stringValue = ""
        let bubble = NSTextField.label("\(note.at.clockString)  \(note.text)", font: .systemFont(ofSize: NSFont.systemFontSize), lines: 0)
        bubble.wantsLayer = true
        bubble.layer?.backgroundColor = NSColor.brandSky.withAlphaComponent(0.16).cgColor
        bubble.layer?.cornerRadius = 10
        bubble.identifier = .init(note.id.uuidString)
        let menu = NSMenu()
        menu.add("Delete", symbol: "trash", isDestructive: true) { [weak self, weak bubble] in
            self?.notes.removeAll { $0.id == note.id }
            if let self { self.journal?.setNotes(self.notes) }
            bubble?.removeFromSuperview()
        }
        bubble.menu = menu
        notesList.addArrangedSubview(bubble)
    }

    @objc func stop() {
        guard !finished, let result = recorder.stop() else { return }
        finished = true
        let names = nameFields.enumerated().map { index, field in
            let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "Speaker \(index + 1)" : trimmed
        }
        let liveText = live.text
        LiveRecording.end()
        live.cancel()
        var written = notes
        let unsent = noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !unsent.isEmpty { written.append(RecordingNote(at: result.duration, text: unsent)) }
        onFinish(Finished(result: result, speakerNames: names, liveText: liveText, written: written))
        journal?.finish()
        onClose?()
    }

    func confirmDiscard() {
        guard !finished else { onClose?(); return }
        Alerts.confirm("Discard Recording?", message: "The recording and the notes written during it are deleted.", action: "Discard", in: view.window) { [weak self] in
            guard let self else { return }
            self.finished = true
            self.recorder.cancel()
            self.live.cancel()
            self.journal?.finish()
            LiveRecording.end()
            self.onClose?()
        }
    }

    /// Ends the clock, the observers and the stop notification (`MeetingRecorder` when the recording ended).
    func tearDown() {
        timer?.invalidate()
        observers.cancelAll()
        NotificationCenter.default.removeObserver(self)
    }
}

/// The level of a microphone as a growing bar.
final class LevelBarView: NSView {
    var level: CGFloat = 0 { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 10).isActive = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let width = max(8, bounds.width * min(1, level))
        NSColor.brandSky.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: radius, yRadius: radius).fill()
    }
}
