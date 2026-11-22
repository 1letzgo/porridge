import AppKit

/// The alert a minute before a meeting (`MeetingAlerts`): a small floating panel in the top right corner that does
/// not take the focus from the app in use, with Record (a Record Meeting for the appointment) and Join (its video
/// link). It also drives the countdown in the menu bar. The calendar is only read.
@MainActor
final class MeetingAlertController: NSObject {
    static let shared = MeetingAlertController()

    /// Called on every tick: the menu bar countdown follows.
    var onTick: (() -> Void)?

    private var timer: Timer?
    private var panel: MeetingAlertPanel?
    private var shown = Set<String>()

    private let scheduler = MeetingAlertScheduler.shared

    /// The next meeting that alerts, still to come or just begun.
    var next: CalendarAppointment? { scheduler.upcoming.first }

    func start() {
        scheduler.onChange = { [weak self] in self?.tick() }
        scheduler.start()
        let timer = Timer(timeInterval: 15, repeats: true) { _ in
            MainActor.assumeIsolated { MeetingAlertController.shared.tick() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Back from sleep: the meetings are read again and a due alert comes at once.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MeetingAlertScheduler.shared.refresh() }
        }
    }

    func tick() {
        let now = Date()
        scheduler.refreshIfStale(now: now)
        if let panel, now > panel.appointment.start.addingTimeInterval(5 * 60) || !MeetingAlerts.isEnabled {
            close()
        }
        if MeetingAlerts.isEnabled, panel == nil, !RecordingWindowController.isRecording,
           let due = scheduler.upcoming.first(where: { MeetingAlerts.isAlertDue(start: $0.start, now: now) && !shown.contains(MeetingAlerts.alertKey($0)) }) {
            shown.insert(MeetingAlerts.alertKey(due))
            show(due)
        }
        onTick?()
    }

    private func show(_ appointment: CalendarAppointment) {
        let panel = MeetingAlertPanel(appointment: appointment)
        panel.onRecord = { [weak self] in
            self?.close()
            Self.record(appointment)
        }
        panel.onJoin = { [weak self] in
            self?.close()
            Self.join(appointment)
        }
        panel.onClose = { [weak self] in self?.close() }
        panel.present()
        self.panel = panel
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// A Record Meeting for the appointment, in the front window.
    static func record(_ appointment: CalendarAppointment) {
        NSApp.activate()
        if RecordingWindowController.isRecording {
            RecordingWindowController.start(title: nil) { _ in }
            return
        }
        Capture.startRecording(for: appointment, state: MainWindowController.front.state)
    }

    /// Opens the video link in its app or the browser; Porridge stays in the back.
    static func join(_ appointment: CalendarAppointment) {
        if let url = appointment.videoURL { NSWorkspace.shared.open(url) }
    }
}

/// The panel itself: floats above other windows and on every Space, never becomes the key window unless a field
/// asks for it (it has none), so typing elsewhere goes on.
final class MeetingAlertPanel: NSPanel {
    let appointment: CalendarAppointment
    var onRecord: (() -> Void)?
    var onJoin: (() -> Void)?
    var onClose: (() -> Void)?

    init(appointment: CalendarAppointment) {
        self.appointment = appointment
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .utilityWindow],
            backing: .buffered, defer: true
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        setAccessibilityLabel(String(localized: "Meeting Alert"))
        build()
    }

    override var canBecomeMain: Bool { false }

    private func build() {
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.blendingMode = .behindWindow

        let time = appointment.start.formatted(.dateTime.hour().minute())
        let caption = NSTextField.label(String(localized: "Meeting at \(time)"), font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), color: .secondaryLabelColor)
        let title = NSTextField.label(appointment.title, font: .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .bold), color: .brandNavy, lines: 2)
        title.preferredMaxLayoutWidth = 270
        var lines: [NSView] = [caption, title]
        if let people = MeetingAlerts.peopleLine(appointment.attendees) {
            lines.append(NSTextField.label(String(localized: "With \(people)"), font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor))
        }

        let record = PillButton(title: String(localized: "Record"), symbol: "mic.fill", tint: .brandSky, target: self, action: #selector(recordTapped))
        record.isFilled = true
        var buttons: [NSView] = [record]
        if appointment.videoURL != nil {
            buttons.append(PillButton(title: String(localized: "Join"), symbol: "video.fill", tint: .brandSky, target: self, action: #selector(joinTapped)))
        }
        buttons.append(NSView())
        let dismiss = NSButton.symbolButton("xmark", label: String(localized: "Dismiss")) { [weak self] in self?.onClose?() }
        buttons.append(dismiss)
        let row = NSStackView.horizontal(buttons, spacing: 8)
        lines.append(row)

        let stack = NSStackView.vertical(lines, spacing: 6)
        stack.setCustomSpacing(12, after: lines[lines.count - 2])
        background.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: background.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -14),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -4),
            background.widthAnchor.constraint(equalToConstant: 320),
        ])
        contentView = background
    }

    /// In the top right corner of the screen with the menu bar, without taking the focus.
    func present() {
        layoutIfNeeded()
        let size = contentView?.fittingSize ?? frame.size
        setContentSize(size)
        if let screen = NSScreen.screens.first ?? NSScreen.main {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 16, y: visible.maxY - frame.height - 12))
        }
        orderFrontRegardless()
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: "\(appointment.title), \(String(localized: "Meeting Alert"))",
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    @objc private func recordTapped() { onRecord?() }
    @objc private func joinTapped() { onJoin?() }
}
