import AppKit

/// The head of the middle column: the list's name after a colored square, as in Things, and what narrows it
/// (the kinds of a bowl or the search, the tags of the search) or empties it (the trash).
final class ListHeaderView: NSView {
    var onFilter: ((KindFilter?) -> Void)?
    var onTag: ((String) -> Void)?
    var onRemoveTag: ((String) -> Void)?
    var onEmptyTrash: (() -> Void)?

    private let icon = NSImageView()
    private let iconBox = NSView()
    private let title = NSTextField.label(font: .systemFont(ofSize: 17, weight: .bold))
    private let filters = NSStackView()
    private let tags = NSStackView()
    private let trailing = NSStackView()
    private var iconTint: NSColor = .brandSky

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
        let stack = NSStackView.vertical([titleRow, filters, tags], spacing: 10)
        addSubview(stack)
        NSLayoutConstraint.activate([
            iconBox.widthAnchor.constraint(equalToConstant: 22),
            iconBox.heightAnchor.constraint(equalToConstant: 22),
            icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            titleRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        title.setAccessibilityLabel(name)
        icon.image = .symbol(symbol, size: 11, weight: .bold)
        icon.contentTintColor = tint.onFill
        iconTint = tint
        iconBox.layer?.backgroundColor = tint.resolved(for: self)

        trailing.arrangedSubviews.forEach { $0.removeFromSuperview() }
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
            title.toolTip = nil
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

    @objc private func emptyTrash() {
        onEmptyTrash?()
    }
}
