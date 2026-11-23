import AppKit

/// The head of the middle column: the list's name after a colored square, as in Things, and what narrows it
/// (the kinds of a bowl or the search, the tags of the search) or empties it (the trash).
final class ListHeaderView: NSView {
    var onFilter: ((KindFilter?) -> Void)?
    var onTag: ((String) -> Void)?
    var onRemoveTag: ((String) -> Void)?
    var onEmptyTrash: (() -> Void)?
    /// The Inbox's "Weekly Review", and a click on the hint of the day.
    var onReview: (() -> Void)?
    var onHint: ((DailyHint) -> Void)?
    /// The Inbox's triage switched on or off, and its "Later" section shown or hidden.
    var onTriage: (() -> Void)?
    var onToggleLater: (() -> Void)?
    /// Today paged a day back (-1) or on (1), and back to today.
    var onStepDay: ((Int) -> Void)?
    var onToday: (() -> Void)?

    private let icon = NSImageView()
    private let iconBox = NSView()
    private let title = NSTextField.label(font: .systemFont(ofSize: 17, weight: .bold))
    private let filters = NSStackView()
    private let tags = NSStackView()
    private let trailing = NSStackView()
    private var iconTint: NSColor = .brandSky
    private let hintRow = DailyHintRow()
    /// The keys of the Inbox's triage, while it is on.
    private let triageKeys = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)

    init() {
        super.init(frame: .zero)
        iconBox.wantsLayer = true
        iconBox.layer?.cornerRadius = 6
        iconBox.layer?.cornerCurve = .continuous
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(icon)
        title.setAccessibilityRole(.staticText)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filters.orientation = .horizontal
        filters.spacing = 6
        tags.orientation = .horizontal
        tags.spacing = 6
        trailing.orientation = .horizontal
        trailing.spacing = 6
        let titleRow = NSStackView.horizontal([iconBox, title, NSView(), trailing], spacing: 8)
        triageKeys.stringValue = String(localized: "J / K  Next, Previous   ·   L  Later   ·   F  File into Bowl   ·   D  Done (To-dos)   ·   Esc  End")
        triageKeys.lineBreakMode = .byTruncatingTail
        triageKeys.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        triageKeys.isHidden = true
        let stack = NSStackView.vertical([titleRow, hintRow, triageKeys, filters, tags], spacing: 10)
        hintRow.onOpen = { [weak self] hint in self?.onHint?(hint) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            iconBox.widthAnchor.constraint(equalToConstant: 22),
            iconBox.heightAnchor.constraint(equalToConstant: 22),
            icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hintRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        iconBox.layer?.backgroundColor = iconTint.resolved(for: self)
    }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        iconBox.layer?.backgroundColor = iconTint.resolved(for: self)
    }

    @MainActor
    func show(page: SidebarPage, library: Library, state: WindowState, kindCounts: [KindFilter: Int]) {
        let (name, symbol, tint): (String, String, NSColor) = switch page {
        case .today: (TodayDay.title(state.todayShownDay), "calendar", .brandNavy)
        case .inbox: ("Inbox", "tray.fill", .brandSky)
        case .todos: ("To-dos", "checklist", .brandTask)
        case .chat: ("Chat", "bubble.left.and.bubble.right.fill", .brandNavy)
        case .project(let id): (library.project(id)?.name ?? "Bowl", "folder.fill", .brandProject)
        case .smartFilter(let id): (SmartFilterStore.shared.filter(id)?.name ?? String(localized: "Smart Filter"), "line.3.horizontal.decrease", .brandNavy)
        case .archive: ("Archive", "archivebox.fill", .brandNavy)
        case .trash: ("Recently Deleted", "trash.fill", .systemRed)
        case .search: ("Search", "magnifyingglass", .brandNavy)
        }
        title.stringValue = name
        title.setAccessibilityLabel(page == .today ? TodayDay.fullDate(state.todayShownDay) : name)
        icon.image = .symbol(symbol, size: 11, weight: .bold)
        icon.contentTintColor = tint.onFill
        iconTint = tint
        iconBox.layer?.backgroundColor = tint.resolved(for: self)

        trailing.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Today: the day before and after (also ← and → in the list), and back to today from another day.
        if page == .today {
            let isToday = state.todayDay == nil
            let previous = ActionButton(title: "", symbol: "chevron.left") { [weak self] in self?.onStepDay?(-1) }
            let today = ActionButton(title: String(localized: "Today")) { [weak self] in self?.onToday?() }
            let next = ActionButton(title: "", symbol: "chevron.right") { [weak self] in self?.onStepDay?(1) }
            for (button, label, key) in [(previous, String(localized: "Previous Day"), "←"), (today, String(localized: "Go to Today"), "T"), (next, String(localized: "Next Day"), "→")] {
                button.controlSize = .small
                button.bezelStyle = .push
                button.toolTip = "\(label) (\(key))"
                button.setAccessibilityLabel(label)
            }
            today.isEnabled = !isToday
            previous.setAccessibilityIdentifier("TodayPreviousDay")
            today.setAccessibilityIdentifier("TodayBackToToday")
            next.setAccessibilityIdentifier("TodayNextDay")
            [previous, today, next].forEach(trailing.addArrangedSubview)
        }
        // The Inbox: what came in this week, and the hint of the day.
        if page == .inbox {
            let review = ActionButton(title: "", symbol: "calendar.badge.checkmark") { [weak self] in self?.onReview?() }
            review.controlSize = .small
            review.bezelStyle = .push
            review.toolTip = String(localized: "Weekly Review")
            review.setAccessibilityLabel(String(localized: "Weekly Review"))
            trailing.addArrangedSubview(review)
            // What was put away for later: shown at the end of the list on a click.
            let later = InboxSnooze.snoozed(library.notes).count
            if later > 0 || state.showsLater {
                let pill = PillButton(title: "Later  \(later)", symbol: "clock", tint: .brandNavy, target: self, action: #selector(toggleLater))
                pill.isFilled = state.showsLater
                pill.toolTip = state.showsLater ? String(localized: "Hide Entries for Later") : String(localized: "Show Entries for Later")
                pill.setAccessibilityLabel(String(localized: "Later, \(later) entries"))
                pill.setAccessibilityValue(state.showsLater ? "Shown" : "Hidden")
                trailing.insertArrangedSubview(pill, at: 0)
            }
            let triage = ActionButton(title: state.isTriaging ? String(localized: "End Triage") : String(localized: "Triage"), symbol: "keyboard") { [weak self] in self?.onTriage?() }
            triage.controlSize = .small
            triage.bezelStyle = .push
            triage.toolTip = String(localized: "Go through the Inbox with the keyboard")
            triage.setAccessibilityIdentifier("InboxTriage")
            trailing.addArrangedSubview(triage)
        }
        triageKeys.isHidden = !(page == .inbox && state.isTriaging)
        let hint = page == .inbox ? DailyHints.shared.current : nil
        hintRow.show(hint)
        if page == .trash, library.notes.contains(where: \.isDeleted) {
            let button = NSButton(title: "Delete All…", target: self, action: #selector(emptyTrash))
            button.controlSize = .small
            button.bezelStyle = .push
            button.hasDestructiveAction = true
            trailing.addArrangedSubview(button)
        }
        // A smart filter: what it asks for, and its editor.
        if case .smartFilter(let id) = page, let filter = SmartFilterStore.shared.filter(id) {
            let names = Dictionary(library.projects.map { (Projects.key($0), $0.name) }, uniquingKeysWith: { a, _ in a })
            title.toolTip = SmartFilters.summary(of: filter.criteria) { names[$0] }
            let button = ActionButton(title: String(localized: "Edit…"), symbol: "slider.horizontal.3") { [weak self] in
                SmartFilterSheet.edit(filter, in: self?.window)
            }
            button.controlSize = .small
            button.bezelStyle = .push
            button.toolTip = String(localized: "Edit Smart Filter")
            trailing.addArrangedSubview(button)
        } else {
            title.toolTip = page == .today ? TodayDay.fullDate(state.todayShownDay) : nil
        }
        // What was searched for, kept as a smart filter.
        if page == .search, state.hasSearch {
            let button = ActionButton(title: String(localized: "Save as Smart Filter…"), symbol: "line.3.horizontal.decrease.circle") { [weak self] in
                let kind: SmartFilterKind? = switch state.kindFilter {
                case .todos?: .openTodos
                case .meetings?: .meetings
                case .notes?: .notes
                case .links?: .links
                case .images?: .images
                case .files?: .files
                case nil: nil
                }
                let criteria = SmartFilterCriteria.fromSearch(text: state.searchText, tags: state.searchTags, kind: kind)
                SmartFilterSheet.create(criteria, in: self?.window) { state.page = .smartFilter($0.id) }
            }
            button.controlSize = .small
            button.bezelStyle = .push
            button.setAccessibilityIdentifier("SaveAsSmartFilter")
            trailing.addArrangedSubview(button)
        }
        // A bowl: share it (with iCloud sync on), or who it is shared with; a click shows the people.
        if case .project(let id) = page, BowlSharing.isAvailable, let project = library.project(id) {
            let info = BowlSharing.shared.info(for: id)
            let button = ActionButton(
                title: info?.summary ?? String(localized: "Share…"), symbol: info == nil ? "person.crop.circle.badge.plus" : "person.2.fill"
            ) { [weak self] in
                if info == nil {
                    BowlShareMac.shared.share(project, in: self?.window)
                } else {
                    BowlShareMac.shared.manage(project, in: self?.window)
                }
            }
            button.controlSize = .small
            button.bezelStyle = .push
            button.isEnabled = !BowlSharing.shared.preparing.contains(id)
            button.toolTip = info == nil ? String(localized: "Share Bowl") : String(localized: "Manage Sharing")
            trailing.addArrangedSubview(button)
        }

        // The kinds: of a bowl only those it holds (the one chosen stays while it is); all of them in the search.
        filters.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var kinds: [KindFilter] = []
        switch page {
        case .project:
            kinds = KindFilter.allCases.filter { (kindCounts[$0] ?? 0) > 0 || state.kindFilter == $0 }
            if kinds.count > 1 || state.kindFilter != nil {
                let total = kindCounts.values.reduce(0, +)
                filters.addArrangedSubview(filterPill(title: "All", count: total, kind: nil, isOn: state.kindFilter == nil, tint: .brandProject))
                for kind in kinds {
                    filters.addArrangedSubview(filterPill(title: kind.title, count: kindCounts[kind] ?? 0, kind: kind, isOn: state.kindFilter == kind, tint: .brandProject))
                }
            }
        case .search:
            for kind in KindFilter.allCases {
                filters.addArrangedSubview(filterPill(title: kind == .todos ? "Open To-dos" : kind.title, count: nil, kind: kind, isOn: state.kindFilter == kind, tint: .brandNavy))
            }
        default:
            break
        }
        filters.isHidden = filters.arrangedSubviews.isEmpty

        // The search's tags: those chosen (a click removes one), and a menu of the others.
        tags.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if page == .search {
            for tag in state.searchTags {
                let pill = PillButton(title: "#\(tag)", symbol: "xmark", tint: .brandSky, target: self, action: #selector(removeTag(_:)))
                pill.identifier = .init(tag)
                pill.setAccessibilityLabel("Remove #\(tag)")
                tags.addArrangedSubview(pill)
            }
            let chosen = Set(state.searchTags.map { $0.lowercased() })
            let open = NoteListContent.tagCounts(library.notes).filter { !chosen.contains($0.key) }
            if !open.isEmpty {
                let popup = NSPopUpButton(frame: .zero, pullsDown: true)
                popup.controlSize = .small
                popup.bezelStyle = .push
                popup.addItem(withTitle: "Tags")
                for tag in open {
                    let item = popup.menu?.addItem(withTitle: "#\(tag.name)  (\(tag.count))", action: #selector(pickTag(_:)), keyEquivalent: "")
                    item?.representedObject = tag.name
                    item?.target = self
                }
                popup.setAccessibilityLabel("Add Tag to Search")
                tags.addArrangedSubview(popup)
            }
        }
        tags.isHidden = tags.arrangedSubviews.isEmpty
    }

    private func filterPill(title: String, count: Int?, kind: KindFilter?, isOn: Bool, tint: NSColor) -> PillButton {
        let text = count.map { "\(title)  \($0)" } ?? title
        let pill = PillButton(title: text, tint: tint, target: self, action: #selector(filterChosen(_:)))
        pill.isFilled = isOn
        pill.identifier = .init(kind?.rawValue ?? "all")
        pill.setAccessibilityLabel(title)
        pill.setAccessibilityValue(isOn ? "Selected" : "")
        return pill
    }

    @objc private func filterChosen(_ sender: NSButton) {
        let kind = KindFilter(rawValue: sender.identifier?.rawValue ?? "")
        // In the search a second click on the chosen kind lets go of it.
        if let kind, (sender as? PillButton)?.isFilled == true, (sender as? PillButton)?.tint == .brandNavy {
            onFilter?(nil)
        } else {
            onFilter?(kind)
        }
    }

    @objc private func pickTag(_ sender: NSMenuItem) {
        if let tag = sender.representedObject as? String { onTag?(tag) }
    }

    @objc private func removeTag(_ sender: NSButton) {
        if let tag = sender.identifier?.rawValue { onRemoveTag?(tag) }
    }

    @objc private func toggleLater() {
        onToggleLater?()
    }

    @objc private func emptyTrash() {
        onEmptyTrash?()
    }
}

/// The hint of the day in the Inbox's head: one quiet line; a click opens what it is about, the cross closes it.
private final class DailyHintRow: NSView {
    var onOpen: ((DailyHint) -> Void)?
    private var hint: DailyHint?
    private let icon = NSImageView()
    private lazy var text = ActionButton(title: "") { [weak self] in
        guard let self, let hint = self.hint else { return }
        self.onOpen?(hint)
    }
    private lazy var close = ActionButton(title: "", symbol: "xmark") { DailyHints.shared.close() }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        icon.contentTintColor = .brandSkyText
        text.isBordered = false
        text.alignment = .left
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = String(localized: "Close Hint")
        close.setAccessibilityLabel(String(localized: "Close Hint"))
        let row = NSStackView.horizontal([icon, text, NSView(), close], spacing: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.brandSky.withAlphaComponent(0.14).resolved(for: self)
    }

    func show(_ hint: DailyHint?) {
        self.hint = hint
        isHidden = hint == nil
        guard let hint else { return }
        icon.image = .symbol(hint.systemImage, size: 12, weight: .semibold)
        text.title = hint.message
        text.setAccessibilityLabel(hint.message)
        needsDisplay = true
    }
}
