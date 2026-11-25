import AppKit
import Carbon.HIToolbox

/// The system-wide shortcuts of Porridge, each one set (or left empty) in Settings › Shortcuts: dictation (held or
/// pressed, `DictationController`), recording a meeting right away, and the command bar.
enum GlobalShortcutAction: String, CaseIterable, Identifiable {
    case dictation
    case recordMeeting
    case commandBar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: String(localized: "Dictation")
        case .recordMeeting: String(localized: "Record Meeting Now")
        case .commandBar: String(localized: "Search or Ask")
        }
    }

    /// Only dictation can be a right-hand modifier key on its own (watched by an event tap).
    var allowsModifierOnly: Bool { self == .dictation }

    private var defaultsKey: String { "globalShortcut." + rawValue }

    /// The shortcut, or nil when there is none (dictation switched off counts as none).
    var key: ShortcutKey? {
        switch self {
        case .dictation:
            guard DictationSettings.enabled else { return nil }
            return ShortcutKey(keyCode: Int(DictationSettings.keyCode), modifiers: Int(DictationSettings.modifiers), label: DictationSettings.keyLabel)
        default:
            guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
            return try? JSONDecoder().decode(ShortcutKey.self, from: data)
        }
    }

    /// Stores the shortcut (nil removes it; for dictation nil switches the shortcut off) and registers it again.
    @MainActor
    func set(_ key: ShortcutKey?) {
        let defaults = UserDefaults.standard
        switch self {
        case .dictation:
            if let key {
                defaults.set(key.keyCode, forKey: DictationSettings.keyCodeKey)
                defaults.set(key.modifiers, forKey: DictationSettings.modifiersKey)
                defaults.set(key.label, forKey: DictationSettings.keyLabelKey)
                defaults.set(true, forKey: DictationSettings.enabledKey)
            } else {
                defaults.set(false, forKey: DictationSettings.enabledKey)
            }
        default:
            if let key, let data = try? JSONEncoder().encode(key) {
                defaults.set(data, forKey: defaultsKey)
            } else {
                defaults.removeObject(forKey: defaultsKey)
            }
        }
        GlobalShortcuts.shared.reload()
    }
}

/// Registers the global shortcuts other than dictation (which `DictationController` keeps, because it watches the key
/// going up too), and finds what a new shortcut clashes with.
@MainActor
final class GlobalShortcuts {
    static let shared = GlobalShortcuts()

    /// Shortcuts that could not be registered: another app holds them.
    private(set) var unavailable: Set<GlobalShortcutAction> = []
    private var hotKeys: [GlobalShortcutAction: GlobalHotKey] = [:]

    private init() {}

    /// Registers every shortcut from the settings. Call again after they change.
    func reload() {
        DictationController.shared.reloadShortcut()
        suspendOwn()
        unavailable = []
        for action in GlobalShortcutAction.allCases where action != .dictation {
            guard let key = action.key else { continue }
            let hotKey = GlobalHotKey()
            hotKey.onPress = { [weak self] in self?.perform(action) }
            if hotKey.register(keyCode: UInt32(key.keyCode), modifiers: UInt32(key.modifiers)) {
                hotKeys[action] = hotKey
            } else {
                unavailable.insert(action)
            }
        }
        if DictationController.shared.shortcutUnavailable { unavailable.insert(.dictation) }
    }

    /// Every shortcut off while a new one is being pressed in the settings.
    func suspend() {
        DictationController.shared.suspendShortcut()
        suspendOwn()
    }

    private func suspendOwn() {
        hotKeys.values.forEach { $0.unregister() }
        hotKeys = [:]
    }

    private func perform(_ action: GlobalShortcutAction) {
        switch action {
        case .dictation:
            DictationController.shared.toggleFromMenu()
        case .recordMeeting:
            Self.recordMeetingNow()
        case .commandBar:
            NSApp.activate()
            CommandBarController.show(for: MainWindowController.front)
        }
    }

    /// A meeting starts recording at once, without the calendar sheet; it lands in the Inbox. A recording that runs
    /// already comes to the front instead.
    static func recordMeetingNow() {
        NSApp.activate()
        let state = WindowState()
        Capture.startRecording(for: nil, state: state)
    }

    // MARK: Conflicts

    /// What `key` would clash with when it became the shortcut of `action`; nil when it is free.
    func conflict(for key: ShortcutKey, action: GlobalShortcutAction) -> String? {
        let others = GlobalShortcutAction.allCases
            .filter { $0 != action }
            .compactMap { other in other.key.map { ShortcutConflicts.Taken(owner: other.title, key: $0) } }
        return ShortcutConflicts.message(for: key, others: others, menu: Self.menuShortcuts())
    }

    /// The key equivalents of Porridge's menu bar, by their item ("Porridge › New Note").
    static func menuShortcuts(in menu: NSMenu? = NSApp.mainMenu, path: String = "") -> [ShortcutConflicts.Taken] {
        guard let menu else { return [] }
        var found: [ShortcutConflicts.Taken] = []
        for item in menu.items {
            if let submenu = item.submenu {
                let name = item.title.isEmpty ? submenu.title : item.title
                found += menuShortcuts(in: submenu, path: path.isEmpty ? name : path + " › " + name)
            }
            guard !item.keyEquivalent.isEmpty else { continue }
            var mask = item.keyEquivalentModifierMask
            // An upper-case key equivalent means Shift.
            if item.keyEquivalent != item.keyEquivalent.lowercased() { mask.insert(.shift) }
            let key = ShortcutKey(keyCode: -1, modifiers: Int(DictationSettings.carbonModifiers(mask)), label: item.keyEquivalent.uppercased())
            found.append(ShortcutConflicts.Taken(owner: path.isEmpty ? item.title : path + " › " + item.title, key: key))
        }
        return found
    }
}
