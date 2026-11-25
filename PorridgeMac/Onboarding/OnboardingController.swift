import AppKit
import AVFoundation

/// First launch: welcome, microphone access, the speech model and its download, done. The AppKit form of
/// `OnboardingView`, as a sheet on the main window.
@MainActor
enum Onboarding {
    static func showIfNeeded(in window: NSWindow?) {
        guard !UserDefaults.standard.bool(forKey: AppSettings.onboardingDoneKey) else { return }
        let controller = OnboardingController {
            // The last step showed the places: no "What's New" card after it.
            WhatsNew.dismiss()
            UserDefaults.standard.set(true, forKey: AppSettings.onboardingDoneKey)
        }
        if let content = window?.contentViewController {
            content.presentAsSheet(controller)
        } else {
            let panel = NSWindow(contentViewController: controller)
            panel.styleMask = [.titled]
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

final class OnboardingController: NSViewController {
    private let onFinish: () -> Void
    private let models = ModelManager.shared
    private var observers: [Observing] = []
    private var step = 0
    private var micGranted: Bool?
    private var isDownloading = false
    private let lastStep = 3

    private let progress = NSStackView.horizontal([], spacing: 8)
    private let content = NSView()
    private lazy var mainButton = NSButton.push("Get Started") { [weak self] in self?.next() }
    private lazy var laterButton = NSButton.push("Later") { [weak self] in
        self?.step = self?.lastStep ?? 3
        self?.showStep()
    }

    // The parts of a step that change while it shows.
    private var micStatus: NSStackView?
    private var engineButtons: [SpeechEngine: NSButton] = [:]
    private var modelStatus = NSStackView()

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for _ in 0...lastStep {
            let bar = NSBox()
            bar.boxType = .custom
            bar.borderWidth = 0
            bar.cornerRadius = 3
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
            progress.addArrangedSubview(bar)
        }
        progress.distribution = .fillEqually
        progress.setAccessibilityElement(true)
        progress.setAccessibilityRole(.progressIndicator)

        content.translatesAutoresizingMaskIntoConstraints = false
        mainButton.keyEquivalent = "\r"
        mainButton.controlSize = .large
        laterButton.isBordered = false
        laterButton.contentTintColor = .controlAccentColor

        let root = NSView()
        for view in [progress, content, mainButton, laterButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: 520),
            root.heightAnchor.constraint(equalToConstant: 600),
            progress.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            progress.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            progress.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            content.bottomAnchor.constraint(equalTo: mainButton.topAnchor, constant: -16),
            mainButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            mainButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            mainButton.bottomAnchor.constraint(equalTo: laterButton.topAnchor, constant: -6),
            laterButton.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            laterButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        view = root
        showStep()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { await ModelManager.shared.refreshASR() }
        observers.append(Observing { [weak self] in self?.render() })
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        observers.cancelAll()
    }

    /// No Escape: the steps end with Done.
    override func cancelOperation(_ sender: Any?) {}

    // MARK: - Steps

    private func showStep() {
        content.subviews.forEach { $0.removeFromSuperview() }
        micStatus = nil
        engineButtons = [:]
        modelStatus = NSStackView.vertical([], spacing: 6, alignment: .centerX)
        let page: NSView
        switch step {
        case 0:
            page = makePage(icon: "text.bubble.fill", title: "Welcome to Porridge",
                            text: "Record meetings and notes. Porridge turns speech into text right on your device, with speaker names.")
        case 1:
            let status = NSStackView.vertical([], spacing: 10, alignment: .centerX)
            micStatus = status
            page = makePage(icon: "mic.fill", title: "Microphone",
                            text: "Porridge needs the microphone to record. Audio stays on your device. DJI Mic receivers and other USB microphones work too.",
                            extra: [status])
        case 2:
            var extra: [NSView] = []
            if AppleSpeech.isSupported {
                extra.append(engineChoice(.parakeet, title: "Parakeet v3", detail: "Most accurate · 25 languages · about 480 MB"))
                extra.append(engineChoice(.apple, title: "Apple (built in)", detail: "Built into macOS · small language pack"))
            }
            let speakers = SettingsCheckbox("Detect speakers (about 30 MB)") {
                UserDefaults.standard.set($0, forKey: AppSettings.speakerDetectionKey)
            }
            speakers.isOn = AppSettings.speakerDetectionEnabled
            extra.append(speakers)
            extra.append(modelStatus)
            page = makePage(icon: "arrow.down.circle.fill", title: "Speech Model",
                            text: "Choose the model that turns speech into text. It runs completely on your device and is downloaded once, preferably over Wi‑Fi.",
                            extra: extra)
        default:
            // The places of the sidebar and what each is for.
            let rows: [NSView] = WhatsNew.places(mac: true).map { place in
                let icon = NSImageView(image: .symbol(place.symbol, size: 15, weight: .semibold))
                icon.contentTintColor = .brandSkyText
                icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
                let title = NSTextField.label(place.title, font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold))
                let text = NSTextField(wrappingLabelWithString: place.text)
                text.textColor = .secondaryLabelColor
                text.isSelectable = false
                text.preferredMaxLayoutWidth = 340
                let texts = NSStackView.vertical([title, text], spacing: 1)
                let row = NSStackView.horizontal([icon, texts], spacing: 10)
                row.alignment = .top
                row.widthAnchor.constraint(equalToConstant: 380).isActive = true
                return row
            }
            let list = NSStackView.vertical(rows, spacing: 10)
            page = makePage(icon: "checkmark.seal.fill", title: "All Set",
                            text: "Porridge has three places in the sidebar, plus Chat and Search or Ask. Everything can be changed later in Settings.",
                            extra: [list])
        }
        content.addSubview(page)
        NSLayoutConstraint.activate([
            page.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            page.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            page.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor),
        ])
        render()
        NSAccessibility.post(element: page, notification: .layoutChanged)
    }

    private func makePage(icon: String, title: String, text: String, extra: [NSView] = []) -> NSView {
        let image = NSImageView(image: .symbol(icon, size: 56))
        image.contentTintColor = .brandSkyText
        let titleLabel = NSTextField.label(title, font: .systemFont(ofSize: 26, weight: .bold))
        titleLabel.alignment = .center
        let body = NSTextField(wrappingLabelWithString: text)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.preferredMaxLayoutWidth = 440
        body.isSelectable = false
        let stack = NSStackView.vertical([image, titleLabel, body] + extra, spacing: 16, alignment: .centerX)
        stack.setCustomSpacing(22, after: body)
        return stack
    }

    private func engineChoice(_ option: SpeechEngine, title: String, detail: String) -> NSView {
        let button = ActionButton(title: title, handler: { [weak self] in
            UserDefaults.standard.set(option.rawValue, forKey: AppSettings.speechEngineKey)
            Task { await ModelManager.shared.refreshASR() }
            self?.render()
        })
        button.setButtonType(.radio)
        button.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        engineButtons[option] = button
        let detailLabel = NSTextField.label(detail, font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
        let stack = NSStackView.vertical([button, detailLabel], spacing: 2)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        detailLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 22).isActive = true
        stack.widthAnchor.constraint(equalToConstant: 320).isActive = true
        return stack
    }

    // MARK: - State

    private var asr: ModelManager.State { models.asr }

    private var canSkipModel: Bool {
        step == 2 && asr != .ready && asr != .installed
    }

    private func render() {
        guard isViewLoaded else { return }
        let state = asr
        for (index, bar) in progress.arrangedSubviews.enumerated() {
            (bar as? NSBox)?.fillColor = index <= step ? .brandSky : .separatorColor
        }
        progress.setAccessibilityLabel("Step \(step + 1) of \(lastStep + 1)")

        mainButton.title = buttonTitle(state)
        mainButton.isEnabled = !isDownloading
        // Never stuck here without a connection: the model can also come later, and a running download goes on.
        laterButton.isHidden = !canSkipModel

        if let micStatus {
            micStatus.arrangedSubviews.forEach { $0.removeFromSuperview() }
            if let micGranted {
                let label = NSTextField.label(
                    micGranted ? "Access granted" : "Access denied – you can change this in Settings.",
                    font: .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                    color: micGranted ? .brandSkyText : .brandLinkText
                )
                let icon = NSImageView(image: .symbol(micGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill", size: 14, weight: .semibold))
                icon.contentTintColor = label.textColor
                micStatus.addArrangedSubview(NSStackView.horizontal([icon, label], spacing: 6))
                if !micGranted {
                    micStatus.addArrangedSubview(NSButton.push("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    })
                }
            }
        }

        let engine = AppSettings.speechEngine
        for (option, button) in engineButtons { button.state = option == engine ? .on : .off }

        if step == 2 {
            modelStatus.arrangedSubviews.forEach { $0.removeFromSuperview() }
            switch state {
            case .downloading(let value):
                let bar = NSProgressIndicator()
                bar.style = .bar
                bar.isIndeterminate = false
                bar.minValue = 0
                bar.maxValue = 1
                bar.doubleValue = value
                bar.translatesAutoresizingMaskIntoConstraints = false
                bar.widthAnchor.constraint(equalToConstant: 320).isActive = true
                modelStatus.addArrangedSubview(bar)
                modelStatus.addArrangedSubview(NSTextField.label(
                    "Downloading… \(Int(value * 100)) %", font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor
                ))
            case .loading:
                let spinner = NSProgressIndicator()
                spinner.style = .spinning
                spinner.controlSize = .small
                spinner.startAnimation(nil)
                modelStatus.addArrangedSubview(NSStackView.horizontal([
                    spinner, NSTextField.label("Preparing…", font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor),
                ]))
            case .ready, .installed:
                modelStatus.addArrangedSubview(statusLine("Model is on your device", symbol: "checkmark.circle.fill", color: .brandSkyText))
            case .failed(let message):
                modelStatus.addArrangedSubview(statusLine(message, symbol: "exclamationmark.triangle.fill", color: .brandDangerText))
            case .notInstalled:
                break
            }
        }
    }

    private func statusLine(_ text: String, symbol: String, color: NSColor) -> NSView {
        let icon = NSImageView(image: .symbol(symbol, size: 13, weight: .semibold))
        icon.contentTintColor = color
        let label = NSTextField.label(text, color: color, lines: 3)
        label.preferredMaxLayoutWidth = 380
        return NSStackView.horizontal([icon, label], spacing: 6, alignment: .firstBaseline)
    }

    private func buttonTitle(_ state: ModelManager.State) -> String {
        switch step {
        case 0: return "Get Started"
        case 1: return micGranted == nil ? "Allow Microphone" : "Continue"
        case 2:
            if isDownloading { return "Downloading…" }
            if case .failed = state { return "Try Again" }
            if state == .ready || state == .installed { return "Continue" }
            return "Download & Continue"
        default: return "Done"
        }
    }

    private func next() {
        switch step {
        case 1 where micGranted == nil:
            Task {
                micGranted = await AudioRecorder.requestPermission()
                render()
            }
        case 2:
            Task { await downloadModels() }
        case lastStep:
            onFinish()
            dismiss(nil)
            if presentingViewController == nil, view.window?.sheetParent == nil { view.window?.close() }
        default:
            step += 1
            showStep()
        }
    }

    private func downloadModels() async {
        let speakerDetection = AppSettings.speakerDetectionEnabled
        if asr == .ready || asr == .installed, !speakerDetection || models.diarizer != .notInstalled {
            step += 1
            showStep()
            return
        }
        isDownloading = true
        render()
        defer {
            isDownloading = false
            render()
        }
        do {
            try await models.ensureASR()
            if speakerDetection { try? await models.ensureDiarizer() }
            // "Later" may have gone on already.
            if step == 2 {
                step = lastStep
                showStep()
            }
        } catch {
            // The error is shown in the status area; the button turns into "Try Again".
        }
    }
}
