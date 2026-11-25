import AppKit

/// The head of the middle column: the list's name after a colored square, as in Things, and what narrows it
/// (the kinds of a bowl or the search, the tags of the search) or empties it (the trash).
final class ListHeaderView: NSView {
    var onFilter: ((KindFilter?) -> Void)?
    var onTag: ((String) -> Void)?
    var onRemoveTag: ((String) -> Void)?
    var onEmptyTrash: (() -> Void)?
    /// A click on the hint of the day (in Today's head).
    var onHint: ((DailyHint) -> Void)?
    /// The Inbox's triage switched on or off, and its segment New / Later (true: Later).
    var onTriage: (() -> Void)?
    var onShowLater: ((Bool) -> Void)?
    /// Today paged a day back (-1) or on (1), and back to today.
    var onStepDay: ((Int) -> Void)?
    var onToday: (() -> Void)?

    private let icon = NSImageView()
    private let iconBox = NSView()
    private let title = NSTextField.label(font: .systemFont(ofSize: 17, weight: .bold))
    /// Today's date under its title.
    private let dateLine = NSTextField.label(font: .systemFont(ofSize: NSFont.smallSystemFontSize + 1), color: .secondaryLabelColor)
    /// The Inbox's New / Later.
    private let segment = NSSegmentedControl()
    private let filters = NSStackView()
    private let tags = NSStackView()
    private let trailing = NSStackView()
    private var iconTint: NSColor = .brandSky
    private let hintRow = DailyHintRow()
    /// The one-time "What's New" card (`WhatsNew`), in Today's head on today.
    private let whatsNew = WhatsNewPanel()
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
        triageKeys.stringValue = String(localized: "J / K  Next, Previous   ·   F  File   ·   L  Later   ·   D  Done   ·   ⌫  Delete   ·   Esc  End")
        triageKeys.lineBreakMode = .byTruncatingTail
        triageKeys.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        triageKeys.isHidden = true
        segment.segmentStyle = .rounded
        segment.trackingMode = .selectOne
        segment.segmentCount = 2
        segment.controlSize = .small
        segment.target = self
        segment.action = #selector(segmentChanged)
        segment.setAccessibilityIdentifier("InboxSegment")
        segment.setAccessibilityLabel(String(localized: "Inbox"))
        dateLine.isHidden = true
        let stack = NSStackView.vertical([titleRow, dateLine, segment, whatsNew, hintRow, triageKeys, filters, tags], spacing: 10)
        stack.setCustomSpacing(2, after: titleRow)
        hintRow.onOpen = { [weak self] hint in self?.onHint?(hint) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            iconBox.widthAnchor.constraint(equalToConstant: 22),
            iconBox.heightAnchor.constraint(equalToConstant: 22),
            icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hintRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            whatsNew.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
    /// `appointmentCount`: a bowl's appointments, rows of All and counted in it.
    func show(page: SidebarPage, library: Library, state: WindowState, kindCounts: [KindFilter: Int], appointmentCount: Int = 0) {
        let (name, symbol, tint): (String, String, NSColor) = switch page {
        case .today: (TodayDay.title(state.todayShownDay), "calendar", .brandNavy)
        case .inbox: ("Inbox", "tray.fill", .brandSky)
        case .bowls: ("Bowls", Places.bowlsSymbol, .brandProject)
        case .todos: ("Open To-dos", "checklist", .brandTask)
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
        dateLine.stringValue = page == .today ? TodayDay.fullDate(state.todayShownDay) : ""
        dateLine.isHidden = page != .today
        // The Bowls place: the one order of the bowls (Settings › General › Sort Bowls By, also the iPhone's).
        if page == .bowls {
            let sort = NSPopUpButton(frame: .zero, pullsDown: false)
            sort.controlSize = .small
            sort.bezelStyle = .push
            for order in HomeList.BowlOrder.allCases { sort.addItem(withTitle: order.title) }
            sort.selectItem(at: HomeList.BowlOrder.allCases.firstIndex(of: HomeList.bowlOrder) ?? 0)
            sort.target = self
            sort.action = #selector(sortChanged(_:))
            sort.toolTip = String(localized: "Sort Bowls By")
            sort.setAccessibilityLabel(String(localized: "Sort Bowls By"))
            sort.setAccessibilityIdentifier("BowlSort")
            trailing.addArrangedSubview(sort)
        }
        // The Inbox: its segment New / Later in the second row, and its triage.
        segment.isHidden = page != .inbox || state.isTriaging
        if page == .inbox {
            let waiting = Inbox.notes(library.notes).count
            let later = InboxSnooze.snoozed(library.notes).count
            segment.setLabel(String(localized: "New  \(waiting)"), forSegment: 0)
            segment.setLabel(String(localized: "Later  \(later)"), forSegment: 1)
            segment.selectedSegment = state.showsLater ? 1 : 0
            let triage = ActionButton(title: state.isTriaging ? String(localized: "End Triage") : String(localized: "Triage"), symbol: "keyboard") { [weak self] in self?.onTriage?() }
            triage.controlSize = .small
            triage.bezelStyle = .push
            triage.toolTip = String(localized: "Go through the Inbox with the keyboard")
            triage.setAccessibilityIdentifier("InboxTriage")
            triage.isEnabled = !state.showsLater && waiting > 0 || state.isTriaging
            trailing.addArrangedSubview(triage)
        }
        triageKeys.isHidden = !(page == .inbox && state.isTriaging)
        // The hint of the day: in Today's head, on today.
        let hint = page == .today && state.todayDay == nil ? DailyHints.shared.current : nil
        hintRow.show(hint)
        whatsNew.isHidden = !(page == .today && state.todayDay == nil && WhatsNew.shows())
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
            if BowlSharing.shared.isReadOnly(id), info != nil { button.setHandler { [weak self] in BowlShareMac.shared.manage(project, in: self?.window) } }
            trailing.addArrangedSubview(button)
        }
        // A bowl: its ⋯ menu, the same as the sidebar row's.
        if case .project(let id) = page, let project = library.project(id) {
            let more = ActionButton(title: "", symbol: "ellipsis.circle") {}
            more.controlSize = .small
            more.bezelStyle = .push
            more.toolTip = String(localized: "Bowl")
            more.setAccessibilityLabel(String(localized: "Bowl"))
            more.setAccessibilityIdentifier("BowlMenu")
            more.setHandler { [weak self, weak more] in
                guard let self, let more else { return }
                let menu = NSMenu()
                BucketActions.addItems(for: project, to: menu, state: state, window: self.window, opens: false)
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 4), in: more)
            }
            trailing.addArrangedSubview(more)
        }

        // The kinds: of a bowl only those it holds (the one chosen stays while it is); all of them in the search.
        filters.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var kinds: [KindFilter] = []
        switch page {
        case .project:
            kinds = KindFilter.allCases.filter { (kindCounts[$0] ?? 0) > 0 || state.kindFilter == $0 }
            if kinds.count > 1 || state.kindFilter != nil {
                let total = kindCounts.values.reduce(0, +) + appointmentCount
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

    @objc private func segmentChanged() {
        onShowLater?(segment.selectedSegment == 1)
    }

    @objc private func sortChanged(_ sender: NSPopUpButton) {
        let orders = HomeList.BowlOrder.allCases
        guard orders.indices.contains(sender.indexOfSelectedItem) else { return }
        UserDefaults.standard.set(orders[sender.indexOfSelectedItem].rawValue, forKey: HomeList.bowlOrderKey)
        Library.shared.setNeedsReload()
    }

    @objc private func emptyTrash() {
        onEmptyTrash?()
    }
}

/// The one-time "What's New" card in Today's head: what moved with the three places, in the Mac's words. "Got It"
/// or the cross puts it away for good (on this Mac).
private final class WhatsNewPanel: NSView {
    private var labels: [NSTextField] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        let heading = NSTextField.label(WhatsNew.title, font: .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .bold), color: .brandNavy)
        let close = ActionButton(title: "", symbol: "xmark") { [weak self] in self?.dismiss() }
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = String(localized: "Close What’s New")
        close.setAccessibilityLabel(String(localized: "Close What’s New"))
        let head = NSStackView.horizontal([NSImageView(image: .symbol("sparkles", size: 13, weight: .semibold)), heading, NSView(), close], spacing: 6)
        var rows: [NSView] = [head]
        for item in WhatsNew.items(mac: true) {
            let icon = NSImageView(image: .symbol(item.symbol, size: 12, weight: .semibold))
            icon.contentTintColor = .brandSkyText
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            let text = NSTextField(wrappingLabelWithString: "")
            let line = NSMutableAttributedString(string: item.title + "  ", attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .semibold), .foregroundColor: NSColor.labelColor])
            line.append(NSAttributedString(string: item.text, attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 1), .foregroundColor: NSColor.secondaryLabelColor]))
            text.attributedStringValue = line
            text.isSelectable = false
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            labels.append(text)
            let row = NSStackView.horizontal([icon, text], spacing: 8)
            row.alignment = .top
            rows.append(row)
        }
        let done = ActionButton(title: String(localized: "Got It")) { [weak self] in self?.dismiss() }
        done.controlSize = .small
        done.bezelStyle = .push
        done.setAccessibilityIdentifier("WhatsNewDone")
        rows.append(done)
        let stack = NSStackView.vertical(rows, spacing: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            head.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(WhatsNew.title)
        setAccessibilityIdentifier("WhatsNew")
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.brandSky.withAlphaComponent(0.1).resolved(for: self)
    }

    /// The lines wrap at the width the list column gives.
    override func layout() {
        let width = max(bounds.width - 10 - 8 - 18 - 8, 120)
        var changed = false
        for label in labels where label.preferredMaxLayoutWidth != width {
            label.preferredMaxLayoutWidth = width
            changed = true
        }
        super.layout()
        if changed { invalidateIntrinsicContentSize(); needsLayout = true }
    }

    private func dismiss() {
        WhatsNew.dismiss()
        isHidden = true
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
