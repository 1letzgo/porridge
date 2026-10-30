import AppKit
import SwiftUI

/// Small floating notice at the top of the screen while dictating. It never takes the keyboard focus.
@MainActor
final class DictationOverlay {
    static let shared = DictationOverlay()

    private var panel: NSPanel?

    func show(controller: DictationController) {
        let panel = panel ?? makePanel(controller: controller)
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(controller: DictationController) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: DictationOverlayView(controller: controller))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 64)
        panel.contentView = host
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 14))
    }
}

private struct DictationOverlayView: View {
    let controller: DictationController

    var body: some View {
        HStack(spacing: 12) {
            switch controller.state {
            case .recording:
                Image(systemName: "mic.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.brandSky)
                    .symbolEffect(.pulse)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Listening …").font(.subheadline.weight(.bold))
                    LevelMeter(level: controller.recorder.levels.max() ?? 0)
                }
                Spacer(minLength: 0)
                Text(controller.recorder.elapsed.clockString)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Color.brandSky)
            case .transcribing:
                ProgressView().controlSize(.small).tint(Color.brandSky)
                Text("Writing it down …").font(.subheadline.weight(.bold))
                Spacer(minLength: 0)
            case .message(let text):
                Image(systemName: "info.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.brandSky)
                Text(text).font(.footnote.weight(.semibold)).lineLimit(3)
                Spacer(minLength: 0)
            case .idle:
                EmptyView()
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 18)
        .frame(width: 340, height: 56)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Look.hairline, lineWidth: 0.5))
        .frame(width: 360, height: 64)
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Look.hairline)
                Capsule()
                    .fill(Color.brandSky)
                    .frame(width: max(6, proxy.size.width * CGFloat(level)))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(height: 6)
    }
}
