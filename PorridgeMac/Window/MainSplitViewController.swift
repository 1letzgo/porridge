import AppKit

/// Sidebar, list, detail and the inspector. The list column shows the notes of the page, or the chats on the chat
/// page; the detail shows the open note or chat; the inspector has two modes, Details (of the selection) and Record
/// (Record Meeting: today's appointments, then the running recording).
///
/// Sidebar and inspector share the room: below `sharedWidth` both do not fit next to list and detail, so opening
/// one closes the other (the last opened wins). A running recording goes on when the inspector closes.
final class MainSplitViewController: NSSplitViewController {
    let state: WindowState
    let sidebar: SidebarViewController
    let content: ContentColumnViewController
    let detail: DetailViewController
    let inspector: InspectorController
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    /// The inspector was opened only to record: it closes again when the recording (or the picker) ends.
    private var openedForRecord = false
    private var lastOpened = Side.inspector
    private var observers: [Observing] = []
    private var didSetUpInspector = false

    /// Below this window width sidebar and inspector are not open together.
    static let sharedWidth: CGFloat = 1130
    private static let inspectorSeenKey = "inspectorFirstLaunchDone"

    private enum Side { case sidebar, inspector }

    init(state: WindowState) {
        self.state = state
        sidebar = SidebarViewController(state: state)
        content = ContentColumnViewController(state: state)
        detail = DetailViewController(state: state)
        inspector = InspectorController(state: state)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        // Wide enough for "Recently Deleted" with its count.
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        let listItem = NSSplitViewItem(contentListWithViewController: content)
        listItem.minimumThickness = 260
        listItem.maximumThickness = 520
        listItem.preferredThicknessFraction = 0.3
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 340
        addSplitViewItem(sidebarItem)
        addSplitViewItem(listItem)
        addSplitViewItem(detailItem)
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 400
        inspectorItem.canCollapse = true
        inspectorItem.holdingPriority = .init(260)
        addSplitViewItem(inspectorItem)
        self.sidebarItem = sidebarItem
        self.inspectorItem = inspectorItem
        splitView.autosaveName = "PorridgeMainSplit"
        splitView.dividerStyle = .thin
        inspector.onModeChosen = { [weak self] mode in self?.show(mode) }
        // While not recording, Record does not stay when another entry is chosen: Details follows the selection.
        observers.append(Observing { [weak self] in
            guard let self else { return }
            _ = self.state.selection
            if self.inspector.mode == .record, !MeetingRecorder.isRecording, self.inspector.recordContent is RecordMeetingViewController {
                self.endRecord()
            }
        })
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didSetUpInspector else { return }
        didSetUpInspector = true
        // First launch with the inspector: open where there is room; afterwards the saved layout says.
        if !UserDefaults.standard.bool(forKey: Self.inspectorSeenKey) {
            UserDefaults.standard.set(true, forKey: Self.inspectorSeenKey)
            let wide = (view.window?.frame.width ?? 0) >= Self.sharedWidth
            inspectorItem.isCollapsed = !wide
            if wide { setInspectorWidth(276) }
        }
        enforceSharedWidth()
    }

    // MARK: Sidebar and inspector share the room

    override func toggleSidebar(_ sender: Any?) {
        let opening = sidebarItem.isCollapsed
        super.toggleSidebar(sender)
        if opening {
            lastOpened = .sidebar
            enforceSharedWidth()
        }
    }

    override func toggleInspector(_ sender: Any?) {
        let opening = inspectorItem.isCollapsed
        if opening {
            openInspector()
        } else {
            keepingWindowFrame { inspectorItem.animator().isCollapsed = true }
            openedForRecord = false
        }
    }

    /// The window got narrower (or one side opened): below `sharedWidth` the side opened earlier closes.
    func enforceSharedWidth() {
        guard let width = view.window?.frame.width, width < Self.sharedWidth,
              !sidebarItem.isCollapsed, !inspectorItem.isCollapsed else { return }
        keepingWindowFrame {
            switch lastOpened {
            case .sidebar: inspectorItem.animator().isCollapsed = true
            case .inspector: sidebarItem.animator().isCollapsed = true
            }
        }
    }

    /// Opens or closes a side (`change`, animated or not) without changing the window's frame: its size and origin
    /// before are given back exactly when the split view (or a column's content) changed them on the way, unless the
    /// user resizes the window meanwhile. Opened while the sidebar still took its room, the inspector made the window
    /// wider; content measured in the opening inspector made it taller (2799 pt instead of 1025).
    private func keepingWindowFrame(_ change: () -> Void) {
        guard let window = view.window, !window.styleMask.contains(.fullScreen) else {
            change()
            return
        }
        let frame = window.frame
        NSAnimationContext.runAnimationGroup { _ in
            change()
        } completionHandler: { [weak window] in
            MainActor.assumeIsolated {
                guard let window, !window.inLiveResize, !window.styleMask.contains(.fullScreen), window.frame != frame else { return }
                window.setFrame(frame, display: true)
            }
        }
    }

    var isInspectorOpen: Bool { !inspectorItem.isCollapsed }

    /// Opens the inspector without changing the window's frame. Where both sides do not fit (below `sharedWidth`),
    /// the sidebar closes first, at once: opened while the sidebar still took its room, the inspector made the
    /// window wider, and the sidebar closing right after made it narrower again by its own width (900 pt became 861
    /// when a recording started). Should the window change anyway, it gets its whole frame back (`keepingWindowFrame`).
    private func openInspector() {
        guard inspectorItem.isCollapsed else { return }
        lastOpened = .inspector
        keepingWindowFrame {
            if let width = view.window?.frame.width, width < Self.sharedWidth, !sidebarItem.isCollapsed {
                sidebarItem.isCollapsed = true
            }
            inspectorItem.animator().isCollapsed = false
        }
        enforceSharedWidth()
    }

    private func setInspectorWidth(_ width: CGFloat) {
        let index = splitView.arrangedSubviews.count - 2
        guard index >= 0 else { return }
        splitView.setPosition(splitView.bounds.width - width - splitView.dividerThickness, ofDividerAt: index)
    }

    // MARK: Details and Record

    /// Opens the inspector in a mode. Record without a recording shows today's appointments to start one.
    func show(_ mode: InspectorController.Mode) {
        if mode == .record, inspector.recordContent == nil {
            guard let controller = view.window?.windowController as? MainWindowController else { return }
            Capture.recordMeeting(in: controller)
            return
        }
        inspector.show(mode)
        openInspector()
    }

    /// Details at a section (a click on a value of the meta line).
    func showDetails(at section: EntryDetails.Section.Kind?) {
        show(.details)
        inspector.details.scroll(to: section)
    }

    /// Record Meeting: the inspector in Record mode with `content` (today's appointments or the recording).
    func showRecord(_ content: NSViewController) {
        if inspectorItem.isCollapsed, inspector.recordContent == nil { openedForRecord = true }
        inspector.setRecordContent(content)
        inspector.show(.record)
        openInspector()
    }

    /// Record Meeting ended (stopped, discarded, cancelled): back to Details, and the inspector closes when it was
    /// opened only for it.
    func endRecord() {
        inspector.setRecordContent(nil)
        inspector.show(.details)
        if openedForRecord {
            openedForRecord = false
            keepingWindowFrame { inspectorItem.animator().isCollapsed = true }
        }
    }

    /// What Record shows (today's appointments or a recording), while the inspector is open in Record mode.
    var recordPaneContent: NSViewController? {
        !inspectorItem.isCollapsed && inspector.mode == .record ? inspector.recordContent : nil
    }
}

/// The inspector of a main window: a segment Details | Record at the top, below it the mode's content.
final class InspectorController: NSViewController {
    enum Mode: Int { case details, record }

    let details: DetailsInspectorViewController
    private(set) var recordContent: NSViewController?
    private(set) var mode = Mode.details
    /// A segment was clicked.
    var onModeChosen: ((Mode) -> Void)?
    private let segment = NSSegmentedControl()
    private let container = NSView()

    init(state: WindowState) {
        details = DetailsInspectorViewController(state: state)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        segment.segmentCount = 2
        segment.setLabel(String(localized: "Details"), forSegment: 0)
        segment.setLabel(String(localized: "Record"), forSegment: 1)
        segment.trackingMode = .selectOne
        segment.selectedSegment = 0
        segment.controlSize = .regular
        segment.segmentDistribution = .fillEqually
        segment.target = self
        segment.action = #selector(segmentChosen)
        segment.setAccessibilityLabel(String(localized: "Inspector"))
        segment.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(segment)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            // Below the toolbar (the window's content runs under it).
            segment.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
            segment.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            segment.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            container.topAnchor.constraint(equalTo: segment.bottomAnchor, constant: 6),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        embed(details)
    }

    @objc private func segmentChosen() {
        let chosen = Mode(rawValue: segment.selectedSegment) ?? .details
        segment.selectedSegment = mode.rawValue
        onModeChosen?(chosen)
    }

    func show(_ new: Mode) {
        _ = view
        mode = new
        segment.selectedSegment = new.rawValue
        let shown: NSViewController? = new == .details ? details : recordContent
        for child in children where child !== shown { child.view.isHidden = true }
        if let shown {
            if shown.parent !== self { embed(shown) }
            shown.view.isHidden = false
        }
    }

    /// Today's appointments or the recording (nil: none).
    func setRecordContent(_ new: NSViewController?) {
        _ = view
        guard new !== recordContent else { return }
        if let old = recordContent, old.parent === self {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        recordContent = new
        if let new {
            embed(new)
            new.view.isHidden = mode != .record
        }
    }

    private func embed(_ child: NSViewController) {
        child.view.removeFromSuperview()
        child.removeFromParent()
        addChild(child)
        container.addSubview(child.view)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        child.view.pinEdges(to: container)
    }
}

/// The middle column: the notes of a page, or the list of chats.
final class ContentColumnViewController: NSViewController {
    private let state: WindowState
    let notes: NoteListViewController
    let chats: ChatListViewController
    private var observing: Observing?

    init(state: WindowState) {
        self.state = state
        notes = NoteListViewController(state: state)
        chats = ChatListViewController(state: state)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = ImportDropView(state: state)
        for child in [notes, chats] as [NSViewController] {
            addChild(child)
            view.addSubview(child.view)
            child.view.pinEdges(to: view)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observing = Observing { [weak self] in
            guard let self else { return }
            let isChat = self.state.page == .chat
            self.notes.view.isHidden = isChat
            self.chats.view.isHidden = !isChat
        }
    }
}
