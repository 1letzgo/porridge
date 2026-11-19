import AppKit

/// Today's appointments as a sheet: picking one starts a recording named after it, "New Meeting" one without.
final class RecordMeetingViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let onStart: (String?) -> Void
    private var appointments: [CalendarAppointment] = []
    private let table = NSTableView()
    private let message = NSTextField.label(color: .secondaryLabelColor, lines: 0)
    private let openSettings = ActionButton(title: "Open Privacy Settings") {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
    private let spinner = NSProgressIndicator()

    /// `onStart` gets the appointment's title, or nil for a meeting that is not in the calendar.
    init(onStart: @escaping (String?) -> Void) {
        self.onStart = onStart
        super.init(nibName: nil, bundle: nil)
        title = "Record Meeting"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let heading = NSTextField.label("Record Meeting", font: .systemFont(ofSize: 17, weight: .bold))
        let newMeeting = PillButton(title: "New Meeting", symbol: "mic.fill", tint: .brandSky, target: self, action: #selector(startNew))
        newMeeting.isFilled = true
        newMeeting.keyEquivalent = "\r"
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

        let cancel = ActionButton(title: "Cancel") { [weak self] in self?.dismiss(nil) }
        cancel.keyEquivalent = "\u{1b}"
        let record = ActionButton(title: "Record") { [weak self] in self?.startPicked() }
        let buttons = NSStackView.horizontal([cancel, NSView(), record], spacing: 8)

        let stack = NSStackView.vertical([heading, newMeeting, today, scroll, message, spinner, openSettings, buttons], spacing: 12)
        stack.setCustomSpacing(18, after: newMeeting)
        let root = NSView()
        root.addSubview(stack)
        stack.pinEdges(to: root, insets: NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20))
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 420),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 260),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
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
        dismiss(nil)
        onStart(nil)
    }

    @objc private func startPicked() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < appointments.count else {
            startNew()
            return
        }
        dismiss(nil)
        onStart(appointments[row].title)
    }
}
