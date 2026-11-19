import AppKit

/// The detail column: the open note, the open chat, or a word that nothing is chosen.
final class DetailViewController: NSViewController {
    private let state: WindowState
    private let library = Library.shared
    private let empty = EmptyMessageView()
    private var current: NSViewController?
    private var currentKey: String?
    private var observing: Observing?
    private var libraryToken: UUID?

    init(state: WindowState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        MainActor.assumeIsolated {
            observing?.cancel()
            library.stopObserving(libraryToken)
        }
    }

    override func loadView() {
        let root = NSView()
        root.addSubview(empty)
        empty.pinEdges(to: root)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observing = Observing { [weak self] in
            guard let self else { return }
            _ = (self.state.page, self.state.selection, self.state.draft, self.state.chatID)
            self.update()
        }
        // A note opened before it was fetched (just made) shows once it is there.
        libraryToken = library.observe { [weak self] in
            guard let self, self.current == nil else { return }
            self.update()
        }
    }

    /// The open note's view, when a note is open.
    var noteDetail: NoteDetailViewController? { current as? NoteDetailViewController }

    private func note(_ id: UUID) -> Note? {
        if let draft = state.draft, draft.id == id { return draft }
        return library.note(id)
    }

    private func update() {
        if state.page == .chat {
            show(key: "chat") { ChatViewController(state: self.state) }
            return
        }
        guard let id = state.openNoteID, let note = note(id) else {
            show(key: nil, nil)
            empty.show(
                title: state.selection.count > 1 ? "\(state.selection.count) Notes Selected" : "No Note Selected",
                message: state.selection.count > 1 ? "Drag them onto a bucket, or use the context menu." : "Pick a note from the list.",
                symbol: "note.text"
            )
            return
        }
        let startsRecording = state.draft?.id == id && state.draftStartsRecording
        show(key: "note-\(id)") { NoteDetailViewController(note: note, state: self.state, startsRecording: startsRecording) }
    }

    private func show(key: String?, _ make: (() -> NSViewController)?) {
        guard key != currentKey else { return }
        currentKey = key
        if let current {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        current = make?()
        empty.isHidden = current != nil
        guard let current else { return }
        addChild(current)
        view.addSubview(current.view)
        current.view.pinEdges(to: view)
    }
}
