import AppKit

/// The Settings window: a toolbar of tabs (General, Recording, Summary, Chat, Models, Dictation), the areas of
/// `SettingsView`. The window takes the height of the tab that shows.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let tabs = SettingsTabController()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 558, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: true
        )
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("")
        super.init(window: window)
        window.contentViewController = tabs
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Opens the window on a tab: "general", "recording", "summary", "chat", "models", "dictation" (nil: where it was).
    func show(tab: String?) {
        if let tab, let index = tabs.tabViewItems.firstIndex(where: { ($0.identifier as? String) == tab }) {
            tabs.selectedTabViewItemIndex = index
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        tabs.fitWindow(animated: false)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        tabs.fitWindow(animated: false)
    }

    func windowWillClose(_ notification: Notification) {
        // A shortcut being recorded ends with the window.
        tabs.tabViewItems.forEach { ($0.viewController as? DictationSettingsPane)?.stopRecording() }
    }
}

/// The tabs; resizes the window to the fitting height of the selected one, keeping its top edge.
final class SettingsTabController: NSTabViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = [.crossfade, .allowUserInteraction]
        add(GeneralSettingsPane(), id: "general", label: "General", symbol: "gearshape")
        add(RecordingSettingsPane(), id: "recording", label: "Recording", symbol: "waveform")
        add(SummarySettingsPane(), id: "summary", label: "Summary", symbol: "text.append")
        add(ChatSettingsPane(), id: "chat", label: "Chat", symbol: "bubble.left.and.bubble.right")
        add(ModelsSettingsPane(), id: "models", label: "Models", symbol: "cpu")
        add(DictationSettingsPane(), id: "dictation", label: "Dictation", symbol: "mic")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func add(_ controller: NSViewController, id: String, label: String, symbol: String) {
        let item = NSTabViewItem(viewController: controller)
        item.identifier = id
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        addTabViewItem(item)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindow(animated: true)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        fitWindow(animated: false)
    }

    func fitWindow(animated: Bool) {
        guard let window = view.window, selectedTabViewItemIndex >= 0,
              let content = tabViewItems[selectedTabViewItemIndex].viewController?.view else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        guard size.height > 0 else { return }
        let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        guard abs(target.height - window.frame.height) > 0.5 || abs(target.width - window.frame.width) > 0.5 else { return }
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        window.setFrame(frame, display: true, animate: animated && window.isVisible)
    }
}
