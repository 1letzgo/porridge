import AppKit

/// Sidebar, list and detail, and on the right Record Meeting when it is open (today's appointments, then the
/// running recording). The list column shows the notes of the page, or the chats on the chat page; the detail shows
/// the open note or chat.
final class MainSplitViewController: NSSplitViewController {
    let state: WindowState
    let sidebar: SidebarViewController
    let content: ContentColumnViewController
    let detail: DetailViewController
    let meeting = MeetingPaneController()
    private var meetingItem: NSSplitViewItem?

    init(state: WindowState) {
        self.state = state
        sidebar = SidebarViewController(state: state)
        content = ContentColumnViewController(state: state)
        detail = DetailViewController(state: state)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        let listItem = NSSplitViewItem(contentListWithViewController: content)
        listItem.minimumThickness = 290
        listItem.maximumThickness = 520
        listItem.preferredThicknessFraction = 0.3
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 380
        addSplitViewItem(sidebarItem)
        addSplitViewItem(listItem)
        addSplitViewItem(detailItem)
        let meetingItem = NSSplitViewItem(inspectorWithViewController: meeting)
        meetingItem.minimumThickness = 320
        meetingItem.maximumThickness = 480
        meetingItem.canCollapse = true
        meetingItem.holdingPriority = .init(260)
        addSplitViewItem(meetingItem)
        self.meetingItem = meetingItem
        splitView.autosaveName = "PorridgeMainSplit"
        splitView.dividerStyle = .thin
        // Closed until Record Meeting opens it (the saved layout may say otherwise).
        meetingItem.isCollapsed = true
    }

    /// Opens the right column with `content` (nil: as it is).
    func showMeetingPane(_ content: NSViewController?) {
        if let content { meeting.show(content) }
        guard let meetingItem, meetingItem.isCollapsed else { return }
        meetingItem.animator().isCollapsed = false
    }

    /// Closes the right column and empties it.
    func hideMeetingPane() {
        meetingItem?.animator().isCollapsed = true
        meeting.show(nil)
    }

    /// What the right column shows (today's appointments or a recording), while it is open.
    var meetingPaneContent: NSViewController? {
        meetingItem?.isCollapsed == false ? meeting.content : nil
    }
}

/// The right column of a main window: Record Meeting.
final class MeetingPaneController: NSViewController {
    private(set) var content: NSViewController?

    override func loadView() {
        view = NSView()
    }

    func show(_ new: NSViewController?) {
        guard new !== content else { return }
        content?.view.removeFromSuperview()
        content?.removeFromParent()
        content = new
        guard let new else { return }
        new.view.removeFromSuperview()
        new.removeFromParent()
        addChild(new)
        view.addSubview(new.view)
        // Below the toolbar (the window's content runs under it).
        new.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            new.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            new.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            new.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            new.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
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
