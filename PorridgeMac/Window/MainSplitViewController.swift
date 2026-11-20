import AppKit

/// Sidebar, list and detail. The list column shows the notes of the page, or the chats on the chat page; the
/// detail shows the open note or chat.
final class MainSplitViewController: NSSplitViewController {
    let state: WindowState
    let sidebar: SidebarViewController
    let content: ContentColumnViewController
    let detail: DetailViewController

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
        splitView.autosaveName = "PorridgeMainSplit"
        splitView.dividerStyle = .thin
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
