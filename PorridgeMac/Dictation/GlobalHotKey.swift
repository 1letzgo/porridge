import Carbon.HIToolbox
import Foundation

/// A system-wide keyboard shortcut (Carbon hot key). Needs no special permission, and reports both
/// the key press and the release, which is what "hold to talk" needs.
final class GlobalHotKey {
    private static var instances: [UInt32: GlobalHotKey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false
    private static let signature: OSType = 0x5052_4447  // "PRDG"

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    private let id: UInt32
    private var reference: EventHotKeyRef?

    init() {
        id = Self.nextID
        Self.nextID += 1
    }

    deinit {
        unregister()
    }

    /// `modifiers` use the Carbon masks: `cmdKey`, `optionKey`, `controlKey`, `shiftKey`.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        Self.installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else { return false }
        Self.instances[id] = self
        return true
    }

    func unregister() {
        if let reference {
            UnregisterEventHotKey(reference)
            self.reference = nil
        }
        Self.instances[id] = nil
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
                let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                DispatchQueue.main.async {
                    guard let key = GlobalHotKey.instances[hotKeyID.id] else { return }
                    if pressed { key.onPress?() } else { key.onRelease?() }
                }
                return noErr
            },
            specs.count, &specs, nil, nil
        )
    }
}
