import AppKit

/// Record Meeting in the right column of the main window: today's appointments; picking one starts a recording
/// named after it, "New Meeting" one without.
final class RecordMeetingViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let onStart: (CalendarAppointment?) -> Void
    private let onCancel: () -> Void
    private var appointments: [CalendarAppointment] = []
    private let table = NSTableView()
    private let message = NSTextField.label(color: .secondaryLabelColor, lines: 0)
    private let openSettings = ActionButton(title: "Open Privacy Settings") {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
    private let spinner = NSProgressIndicator()

    /// `onStart` gets the appointment, or nil for a meeting that is not in the calendar.
    init(onStart: @escaping (CalendarAppointment?) -> Void, onCancel: @escaping () -> Void) {
        self.onStart = onStart
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
        title = "Record Meeting"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let heading = NSTextField.label("Record Meeting", font: .systemFont(ofSize: 17, weight: .bold))
        let newMeeting = PillButton(title: "New Meeting", symbol: "mic.fill", tint: .brandSky, target: self, action: #selector(startNew))
        newMeeting.isFilled = true
        newMeeting.setAccessibilityLabel("New Meeting")
        let today = NSTextField.label("Today", font: .systemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .bold), color: .brandSkyText)

        let column = NSTableColumn(identifier: .init("appointment"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.usesAutomaticRowHeights = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(startPicked)
        table.setAccessibilityLabel("Today's Appointments")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        openSettings.isHidden = true

        // The other side of the call, from the Mac's sound; remembered for the next meeting.
        let systemAudio = SettingsCheckbox("Include system audio") { MeetingAudio.includesSystemAudio = $0 }
        systemAudio.isOn = MeetingAudio.includesSystemAudio
        systemAudio.toolTip = "Records what your Mac plays, such as the other side of a Zoom, Meet or Teams call, next to your microphone. Works with headphones too."
        let systemAudioNote = NSTextField.label(
            "Your microphone is you, your Mac's sound is the others.",
            font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor, lines: 0)

        // Wrapped over several lines in the narrow column.
        for label in [systemAudioNote, message] { label.lineBreakMode = .byWordWrapping }
        let cancel = ActionButton(title: "Cancel") { [weak self] in self?.onCancel() }
        let record = ActionButton(title: "Record") { [weak self] in self?.startPicked() }
        let buttons = NSStackView.horizontal([cancel, NSView(), record], spacing: 8)

        let stack = NSStackView.vertical([heading, newMeeting, today, scroll, message, spinner, openSettings, systemAudio, systemAudioNote, buttons], spacing: 12)
        stack.setCustomSpacing(18, after: newMeeting)
        stack.setCustomSpacing(2, after: systemAudio)
        let root = NSView()
        root.addSubview(stack)
        stack.pinEdges(to: root, insets: NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20))
        // The appointments take the height the column has.
        let filler = NSView()
        stack.insertArrangedSubview(filler, at: stack.arrangedSubviews.firstIndex(of: systemAudio) ?? 0)
        filler.setContentHuggingPriority(.init(1), for: .vertical)
        scroll.setContentHuggingPriority(.init(2), for: .vertical)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            systemAudioNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { @MainActor in await load() }
    }

    private func load() async {
        var status = CalendarAccess.status
        if status == .notDetermined {
            spinner.startAnimation(nil)
            _ = await CalendarAccess.requestAccess()
            status = CalendarAccess.status
            spinner.stopAnimation(nil)
        }
        switch status {
        case .granted:
            appointments = CalendarAccess.todaysAppointments()
            table.reloadData()
            message.stringValue = appointments.isEmpty ? "No appointments in your calendars today." : ""
            message.isHidden = !appointments.isEmpty
        case .denied:
            message.stringValue = "Calendar access is off. Allow Porridge to read your calendars to see today's appointments here."
            openSettings.isHidden = false
        case .notDetermined:
            break
        }
        table.enclosingScrollView?.isHidden = appointments.isEmpty
    }

    func numberOfRows(in tableView: NSTableView) -> Int { appointments.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let appointment = appointments[row]
        let title = NSTextField.label(appointment.title, font: .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold), color: .brandNavy, lines: 2)
        let time = appointment.isAllDay
            ? String(localized: "All day")
            : "\(appointment.start.formatted(.dateTime.hour().minute())) – \(appointment.end.formatted(.dateTime.hour().minute()))"
        let detail = NSTextField.label("\(time) · \(appointment.calendarName)", font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), color: .secondaryLabelColor)
        let mic = NSImageView(image: .symbol("mic.fill", size: 14))
        mic.contentTintColor = .brandSkyText
        let text = NSStackView.vertical([title, detail], spacing: 3)
        let row = NSStackView.horizontal([text, NSView(), mic], spacing: 10)
        let cell = NSTableCellView()
        cell.addSubview(row)
        row.pinEdges(to: cell, insets: NSEdgeInsets(top: 8, left: 6, bottom: 8, right: 6))
        cell.setAccessibilityLabel("\(appointment.title), \(time)")
        return cell
    }

    @objc private func startNew() {
        onStart(nil)
    }

    @objc private func startPicked() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < appointments.count else {
            startNew()
            return
        }
        onStart(appointments[row])
    }
}
