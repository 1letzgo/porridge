import AppKit

/// Small floating notice at the top of the screen while dictating. It never takes the keyboard focus.
@MainActor
final class DictationOverlay {
    static let shared = DictationOverlay()

    private var panel: NSPanel?
    private var content: DictationOverlayView?

    func show(controller: DictationController) {
        let panel = panel ?? makePanel(controller: controller)
        self.panel = panel
        content?.start()
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        content?.stop()
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
        let view = DictationOverlayView(controller: controller)
        view.frame = NSRect(x: 0, y: 0, width: 360, height: 64)
        panel.contentView = view
        content = view
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 14))
    }
}

/// A capsule of material: listening with the level and the clock, writing it down, or a short message.
private final class DictationOverlayView: NSView {
    private let controller: DictationController
    private let capsule = NSVisualEffectView()
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let title = NSTextField.label(font: .systemFont(ofSize: NSFont.systemFontSize, weight: .bold))
    private let meter = LevelMeterView()
    private let clock = NSTextField.label(font: .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold), color: .brandSkyText)
    private var observing: Observing?
    private var timer: Timer?

    init(controller: DictationController) {
        self.controller = controller
        super.init(frame: .zero)
        capsule.material = .hudWindow
        capsule.blendingMode = .behindWindow
        capsule.state = .active
        capsule.wantsLayer = true
        capsule.layer?.cornerRadius = 28
        capsule.layer?.masksToBounds = true
        capsule.frame = NSRect(x: 10, y: 4, width: 340, height: 56)
        addSubview(capsule)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        title.maximumNumberOfLines = 3
        title.lineBreakMode = .byWordWrapping
        let text = NSStackView.vertical([title, meter], spacing: 5)
        let row = NSStackView.horizontal([icon, spinner, text, NSView(), clock], spacing: 12)
        capsule.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -18),
            row.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
            meter.widthAnchor.constraint(equalToConstant: 150),
            meter.heightAnchor.constraint(equalToConstant: 6),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 250),
        ])
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func start() {
        observing?.cancel()
        observing = Observing { [weak self] in self?.render() }
        // The level and the clock change many times a second: a timer instead of following each change.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        observing?.cancel()
        observing = nil
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard controller.state == .recording else { return }
        meter.level = CGFloat(controller.recorder.levels.max() ?? 0)
        clock.stringValue = controller.recorder.elapsed.clockString
    }

    private func render() {
        switch controller.state {
        case .recording:
            icon.isHidden = false
            icon.image = .symbol("mic.fill", size: 17, weight: .bold)
            icon.contentTintColor = .brandSkyText
            spinner.stopAnimation(nil)
            title.stringValue = "Listening…"
            title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .bold)
            meter.isHidden = false
            clock.isHidden = false
            tick()
        case .transcribing:
            icon.isHidden = true
            spinner.startAnimation(nil)
            title.stringValue = "Writing it down…"
            meter.isHidden = true
            clock.isHidden = true
        case .message(let text):
            icon.isHidden = false
            icon.image = .symbol("info.circle.fill", size: 17)
            icon.contentTintColor = .brandSkyText
            spinner.stopAnimation(nil)
            title.stringValue = text
            title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            meter.isHidden = true
            clock.isHidden = true
        case .idle:
            break
        }
        setAccessibilityLabel(title.stringValue)
    }
}

/// The level of the microphone as a growing bar.
private final class LevelMeterView: NSView {
    var level: CGFloat = 0 { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        track.fill()
        let width = max(6, bounds.width * min(1, level))
        let bar = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.brandSky.setFill()
        bar.fill()
    }
}
