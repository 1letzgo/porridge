import AppKit
import SwiftUI

/// The undo toast on the Mac: a small floating bar at the bottom of the main window in front, with "Undo". It
/// stays while the pointer rests on it. ⌘Z undoes the same action (the window's undo manager has it too).
@MainActor
final class UndoToastPanel {
    static let shared = UndoToastPanel()

    private var panel: NSPanel?
    private var observer: Observing?
    private weak var host: NSWindow?

    /// Once at launch: the toast follows `UndoToast.shared`, and its actions go into the window's undo manager.
    static func start() {
        UndoToast.shared.undoManagerProvider = {
            (NSApp.keyWindow?.windowController as? MainWindowController)?.window?.undoManager
                ?? MainWindowController.frontIfAny?.window?.undoManager
        }
        shared.observer = Observing {
            _ = UndoToast.shared.current
            shared.update()
        }
    }

    #if DEBUG
    /// `DebugDriver`'s `shot-toast`.
    var debugWindow: NSWindow? { panel?.isVisible == true ? panel : nil }
    #endif

    private func update() {
        guard UndoToast.shared.current != nil, let window = MainWindowController.frontIfAny?.window, window.isVisible else {
            hide()
            return
        }
        let panel = self.panel ?? makePanel()
        if host !== window {
            host?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            host = window
        }
        place(panel, in: window)
        panel.orderFront(nil)
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: UndoToast.shared.current?.message ?? "", .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    private func hide() {
        guard let panel else { return }
        host?.removeChildWindow(panel)
        host = nil
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 60),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        panel.isFloatingPanel = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: MacUndoToast())
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func place(_ panel: NSPanel, in window: NSWindow) {
        // Room around the capsule for its shadow; the capsule sits 16 pt above the window's bottom edge.
        let size = NSSize(width: 440, height: 60)
        let frame = window.frame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 4, width: size.width, height: size.height), display: true)
    }
}

/// The toast itself, the same navy capsule as on the iPhone: what happened, then "Undo".
private struct MacUndoToast: View {
    var toast = UndoToast.shared

    var body: some View {
        ZStack {
            if let offer = toast.current {
                HStack(spacing: 10) {
                    Image(systemName: offer.systemImage)
                        .foregroundStyle(.white.opacity(0.85))
                        .accessibilityHidden(true)
                    Text(offer.message)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        toast.undo()
                    } label: {
                        Text("Undo")
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(.white.opacity(0.16), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Undo (⌘Z)")
                    Button {
                        toast.dismiss()
                    } label: {
                        Image(systemName: "xmark").font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                .font(.system(size: 12.5))
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .frame(height: 36)
                .background(Color(nsColor: .toastFill), in: Capsule())
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                .frame(maxWidth: 420)
                .onHover { toast.hold($0) }
            }
        }
        .frame(width: 440, height: 60)
    }
}
