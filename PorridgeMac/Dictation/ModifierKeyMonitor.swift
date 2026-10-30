import AppKit
import Carbon.HIToolbox

/// Watches one modifier key (the right Option key, say) system-wide, so it can be the dictation shortcut
/// on its own. Carbon hot keys cannot do that; an event tap can, but only once the app may watch the
/// keyboard (the Accessibility permission, which pasting needs anyway, or Input Monitoring).
final class ModifierKeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var keyCode: Int64 = 0
    private var mask: CGEventFlags = []
    private var isDown = false

    /// The device-specific flag of a modifier key: the left and right keys have their own bits, so the
    /// right Option key can be told from the left one even when both are down.
    static func mask(for keyCode: Int) -> CGEventFlags? {
        switch keyCode {
        case kVK_RightOption: CGEventFlags(rawValue: 0x40)
        case kVK_RightCommand: CGEventFlags(rawValue: 0x10)
        case kVK_RightShift: CGEventFlags(rawValue: 0x04)
        case kVK_RightControl: CGEventFlags(rawValue: 0x2000)
        default: nil
        }
    }

    /// Whether macOS lets this app watch the keyboard.
    static var hasPermission: Bool {
        AXIsProcessTrusted() || CGPreflightListenEventAccess()
    }

    deinit {
        stop()
    }

    /// Starts watching `keyCode`. Returns `false` when the key is not a modifier or the tap could not be made.
    @discardableResult
    func start(keyCode: Int) -> Bool {
        stop()
        guard let mask = Self.mask(for: keyCode) else { return false }
        self.keyCode = Int64(keyCode)
        self.mask = mask

        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
            callback: { _, type, event, info in
                if let info {
                    Unmanaged<ModifierKeyMonitor>.fromOpaque(info).takeUnretainedValue().handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: info
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        isDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // macOS switches a slow tap off; switch it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged, event.getIntegerValueField(.keyboardEventKeycode) == keyCode else { return }
        let down = event.flags.contains(mask)
        guard down != isDown else { return }
        isDown = down
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if down { self.onPress?() } else { self.onRelease?() }
        }
    }
}
