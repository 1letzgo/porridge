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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 48),
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
        let size = NSSize(width: 428, height: 48)
        let frame = window.frame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 20, width: size.width, height: size.height), display: true)
    }
}

/// The toast itself: what happened, then "Undo".
private struct MacUndoToast: View {
    var toast = UndoToast.shared

    var body: some View {
        if let offer = toast.current {
            HStack(spacing: 10) {
                Image(systemName: offer.systemImage)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(offer.message)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Undo") { toast.undo() }
                    .buttonStyle(.borderless)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(nsColor: .brandSkyText))
                    .help("Undo (⌘Z)")
                Button {
                    toast.dismiss()
                } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .frame(width: 420)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
            .padding(4)
            .onHover { toast.hold($0) }
        }
    }
}
