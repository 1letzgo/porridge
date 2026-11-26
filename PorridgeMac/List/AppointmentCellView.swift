import AppKit

/// An appointment of the day in Today's list (or of a bowl, among its entries): time, title, its bowl and how many entries are linked; the button at
/// the end (and the context menu) record a meeting for it, start a note for it or file it into a bowl.
final class AppointmentCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("appointment")
    private let icon = KindIconView()
    /// At most two lines, broken between words; the second ends in "…" (a wrapping label that cuts its last line).
    private let name = NSTextField.label(font: .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .medium), lines: 2)
    private let summary = NSTextField.label(font: .systemFont(ofSize: NSFont.systemFontSize), color: .secondaryLabelColor)
    private let actions = NSButton()
    private var appointment: CalendarAppointment?
    /// Builds the menu of the appointment (`AppointmentActions.menu`).
    var menuProvider: ((CalendarAppointment) -> NSMenu)?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.symbol = "calendar"
        icon.tint = .brandNavy
        summary.lineBreakMode = .byTruncatingTail
        actions.image = .symbol("ellipsis.circle", size: 15, weight: .regular, label: String(localized: "Appointment Actions"))
        actions.isBordered = false
        actions.contentTintColor = .secondaryLabelColor
        actions.target = self
        actions.action = #selector(showActions)
        actions.toolTip = String(localized: "Appointment Actions")
        actions.setContentHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)
        // The labels give way (the line "… · 2 linked entries" ends in "…"), never the ⋯ button: with the labels'
        // default resistance the row grew past the column and pushed the button out of view.
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView.vertical([name, summary], spacing: 3)
        // The text takes the width of the row; the button keeps its own at the end.
        text.setHuggingPriority(.init(1), for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView.horizontal([icon, text, actions], spacing: 12, alignment: .centerY)
        row.distribution = .fill
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            // The title is as wide as the text column (as the two-line preview of `NoteCellView`): a wrapping label
            // works out its height for the width it is given. Only "at most as wide", it kept its one-line width as
            // its own, was squeezed to the column and measured one line high, so it was cut after the first line.
            name.widthAnchor.constraint(equalTo: text.widthAnchor),
            summary.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Two lines for a long title: measured at the width the row really has.
        fitWrappingLabels([name])
    }

    @MainActor
    /// `showsBowl`: names its bowl (not in the bowl itself); `linked`: how many entries are under it (a bowl's list),
    /// else those linked to the occurrence as Today shows them.
    func show(_ appointment: CalendarAppointment, notes: [Note], showsDay: Bool = false, showsBowl: Bool = true, linked: Int? = nil) {
        self.appointment = appointment
        let over = appointment.end < Date()
        name.stringValue = appointment.title
        name.textColor = over ? .secondaryLabelColor : .labelColor
        var parts = [AppointmentActions.time(appointment, showsDay: showsDay) + (appointment.isRecurring ? " ↻" : "")]
        if showsBowl, let bowl = AppointmentLinks.shared.bowl(for: appointment), let project = Library.shared.project(key: bowl) {
            parts.append(project.name)
        }
        let linked = linked ?? TodayTodos.shown(AppointmentLinks.shared.notes(for: appointment, among: notes)).count
        if linked > 0 { parts.append(linked == 1 ? String(localized: "1 linked entry") : String(localized: "\(linked) linked entries")) }
        summary.stringValue = parts.joined(separator: " · ")
        setAccessibilityLabel("\(appointment.title), \(summary.stringValue)")
    }

    @objc private func showActions() {
        guard let appointment, let menu = menuProvider?(appointment) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: actions.bounds.height + 4), in: actions)
    }
}

/// Menus about appointments: what to do with one of the day, and which one an entry belongs to.
@MainActor
enum AppointmentActions {
    /// "18:00–22:00", "All Day"; with the day "Mon 24 Nov, 18:00–22:00" ("Today, …"), as in a bowl.
    static func time(_ appointment: CalendarAppointment, showsDay: Bool) -> String {
        let hours = "\(appointment.start.formatted(date: .omitted, time: .shortened))–\(appointment.end.formatted(date: .omitted, time: .shortened))"
        guard showsDay else { return appointment.isAllDay ? String(localized: "All Day") : hours }
        let day = AppointmentRef.when(start: appointment.start, isAllDay: true)
        return appointment.isAllDay ? day : "\(day), \(hours)"
    }

    /// The appointment opened with a click on its row, read only (the calendar is never changed): title, when,
    /// where, the calendar, its bowl, the entries linked to it (a click opens one), Record Meeting and New Note.
    static func popover(for appointment: CalendarAppointment, in controller: MainWindowController?, onOpenNote: @escaping (Note) -> Void) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        let links = AppointmentLinks.shared
        var views: [NSView] = []
        let title = NSTextField.label(appointment.title, font: .systemFont(ofSize: NSFont.systemFontSize + 2, weight: .semibold), lines: 3)
        views.append(title)
        var facts = [time(appointment, showsDay: true)]
        if appointment.isRecurring { facts.append(String(localized: "Repeats")) }
        if let location = appointment.location { facts.append(location) }
        if !appointment.calendarName.isEmpty { facts.append(appointment.calendarName) }
        if let bowl = links.bowl(for: appointment), let project = Library.shared.project(key: bowl) {
            facts.append(String(localized: "Bowl: \(project.name)"))
        }
        for fact in facts { views.append(NSTextField.label(fact, color: .secondaryLabelColor, lines: 2)) }
        let linked = links.notes(for: appointment, among: Library.shared.notes)
        if !linked.isEmpty {
            views.append(NSTextField.label(String(localized: "Linked Entries"), font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), color: .secondaryLabelColor))
            for note in linked.prefix(8) {
                let button = ActionButton(title: note.displayTitle) { [weak popover] in
                    popover?.close()
                    onOpenNote(note)
                }
                button.bezelStyle = .inline
                button.isBordered = false
                button.contentTintColor = .linkColor
                views.append(button)
            }
        }
        var buttons: [NSView] = []
        if appointment.end > Date() {
            buttons.append(ActionButton(title: String(localized: "Record Meeting"), symbol: "mic") { [weak popover, weak controller] in
                popover?.close()
                guard let controller else { return }
                Capture.startRecording(for: appointment, state: controller.state, in: controller)
            })
        }
        buttons.append(ActionButton(title: String(localized: "New Note"), symbol: "square.and.pencil") { [weak popover, weak controller] in
            popover?.close()
            controller?.addNote(for: appointment)
        })
        views.append(NSStackView.horizontal(buttons, spacing: 8))
        let stack = NSStackView.vertical(views, spacing: 6)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.setAccessibilityIdentifier("AppointmentPopover")
        let content = NSViewController()
        content.view = stack
        stack.widthAnchor.constraint(equalToConstant: 300).isActive = true
        popover.contentViewController = content
        return popover
    }

    /// Record Meeting (while it is not over), New Note, and Bowl with the active bowls.
    static func menu(for appointment: CalendarAppointment, in controller: MainWindowController?) -> NSMenu {
        let menu = NSMenu()
        if appointment.end > Date() {
            menu.addItem(ActionMenuItem(String(localized: "Record Meeting"), symbol: "mic") { [weak controller] in
                guard let controller else { return }
                Capture.startRecording(for: appointment, state: controller.state, in: controller)
            })
        }
        menu.addItem(ActionMenuItem(String(localized: "New Note"), symbol: "square.and.pencil") { [weak controller] in
            controller?.addNote(for: appointment)
        })
        menu.addItem(.separator())
        let bowls = NSMenu()
        let current = AppointmentLinks.shared.bowl(for: appointment)
        let none = ActionMenuItem(String(localized: "None")) {
            AppointmentLinks.shared.setBowl(nil, for: appointment, notes: Library.shared.notes, in: Library.shared.context)
        }
        none.state = current == nil ? .on : .off
        bowls.addItem(none)
        for project in Library.shared.activeProjects where !BowlSharing.shared.isReadOnly(project.id) {
            let key = Projects.key(project)
            let item = ActionMenuItem(project.name) {
                AppointmentLinks.shared.setBowl(key, for: appointment, notes: Library.shared.notes, in: Library.shared.context)
            }
            item.state = current == key ? .on : .off
            bowls.addItem(item)
        }
        let bowlItem = NSMenuItem(title: String(localized: "Bowl"), action: nil, keyEquivalent: "")
        bowlItem.image = .symbol("folder", size: 13, weight: .regular)
        bowlItem.submenu = bowls
        menu.addItem(bowlItem)
        return menu
    }

    /// The appointments to link an entry to: those of its own day, of today, and of the days around its day; the
    /// linked one ticked, and a way to remove the link.
    static func linkMenu(for note: Note) -> NSMenu {
        let menu = NSMenu()
        let links = AppointmentLinks.shared
        let current = links.appointment(for: note.id)
        switch CalendarAccess.status {
        case .notDetermined:
            menu.addItem(ActionMenuItem(String(localized: "Show Appointments…"), symbol: "calendar") {
                Task { await TodayCalendar.shared.requestAccess() }
            })
            return menu
        case .denied:
            let item = NSMenuItem(title: String(localized: "Porridge may not read your calendars"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return menu
        case .granted:
            break
        }
        let calendar = Calendar.current
        let ownDay = calendar.startOfDay(for: current?.start ?? note.createdAt)
        func items(for day: Date) -> [NSMenuItem] {
            CalendarAccess.appointments(on: day).filter { !$0.isDeclined }.map { appointment in
                let time = appointment.isAllDay ? String(localized: "All Day") : appointment.start.formatted(date: .omitted, time: .shortened)
                let item = ActionMenuItem("\(time)  \(appointment.title)") {
                    links.link(note, to: appointment, in: note.modelContext ?? Library.shared.context)
                }
                item.state = current?.matches(appointment) == true ? .on : .off
                return item
            }
        }
        func header(_ day: Date) -> NSMenuItem {
            NSMenuItem.sectionHeader(title: AppointmentRef.when(start: day, isAllDay: true))
        }
        let own = items(for: ownDay)
        menu.addItem(header(ownDay))
        if own.isEmpty {
            let item = NSMenuItem(title: String(localized: "No Appointments"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        own.forEach(menu.addItem)
        let today = calendar.startOfDay(for: Date())
        if today != ownDay {
            let todays = items(for: today)
            if !todays.isEmpty {
                menu.addItem(.separator())
                menu.addItem(header(today))
                todays.forEach(menu.addItem)
            }
        }
        // A week either side of the entry's day, each as a submenu.
        let other = NSMenu()
        for offset in -7...7 where offset != 0 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: ownDay), day != today else { continue }
            let entries = items(for: day)
            guard !entries.isEmpty else { continue }
            let sub = NSMenu()
            entries.forEach(sub.addItem)
            let item = NSMenuItem(title: AppointmentRef.when(start: day, isAllDay: true), action: nil, keyEquivalent: "")
            item.submenu = sub
            other.addItem(item)
        }
        if !other.items.isEmpty {
            menu.addItem(.separator())
            let item = NSMenuItem(title: String(localized: "Other Days"), action: nil, keyEquivalent: "")
            item.submenu = other
            menu.addItem(item)
        }
        if current != nil {
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem(String(localized: "Remove Appointment"), symbol: "calendar.badge.minus") {
                links.link(note, to: nil, in: nil)
            })
        }
        return menu
    }
}
