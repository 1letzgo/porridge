import AppKit
import AVFoundation
import SwiftData

/// Recording: the speech model and language (transcription always runs on this Mac), the microphone, and who said
/// what: speaker detection with its model, then the known voices.
final class RecordingSettingsPane: SettingsPane {
    private let models = ModelManager.shared
    private let failures = FailureWatch()
    private var libraryToken: UUID?

    private lazy var enginePopUp = SettingsPopUp { [weak self] index in
        let engines = SpeechEngine.available
        guard index >= 0, index < engines.count else { return }
        UserDefaults.standard.set(engines[index].rawValue, forKey: AppSettings.speechEngineKey)
        self?.refreshASR()
    }
    private let engineLabel = NSTextField.label()
    private lazy var appleRow = ModelStateRow(title: "Apple Speech", subtitle: "On this device · built into the system") { [weak self] in
        Task { try? await self?.models.ensureLocalASR() }
    }
    private lazy var parakeetRow = ModelStateRow(
        title: "Parakeet TDT v3", subtitle: "On this device · 25 languages · approx. 480 MB",
        onDelete: { [weak self] in self?.confirmDelete("Parakeet TDT v3") { await ModelManager.shared.deleteASR() } },
        onCancel: { Task { await ModelManager.shared.deleteASR() } }
    ) {
        Task {
            let models = ModelManager.shared
            if AppSettings.speechEngine == .parakeet { try? await models.ensureLocalASR() } else { await models.downloadSpareParakeet() }
        }
    }
    private lazy var languagePopUp = SettingsPopUp { [weak self] index in
        let languages = AppSettings.languages
        guard index >= 0, index < languages.count else { return }
        UserDefaults.standard.set(languages[index].code, forKey: AppSettings.languageKey)
        self?.refreshASR()
    }
    private let microphoneLabel = NSTextField.label()
    private lazy var recordsNewNotes = SettingsCheckbox("Record New Notes Automatically") {
        UserDefaults.standard.set($0, forKey: AppSettings.recordsNewNotesKey)
    }
    private lazy var speakerRow = ModelStateRow(
        title: "Speaker Model", subtitle: "pyannote · on this device · approx. 30 MB",
        onDelete: { [weak self] in self?.confirmDelete("Speaker Detection") { await ModelManager.shared.deleteDiarizer() } }
    ) {
        Task { try? await ModelManager.shared.ensureDiarizer() }
    }
    private lazy var detectSpeakers = SettingsCheckbox("Detect Speakers") { [weak self] on in
        UserDefaults.standard.set(on, forKey: AppSettings.speakerDetectionKey)
        self?.render()
    }
    private lazy var recognizeVoices = SettingsCheckbox("Recognize Known Voices") {
        UserDefaults.standard.set($0, forKey: AppSettings.voiceRecognitionKey)
    }
    private let voiceCount = NSTextField.label(color: .secondaryLabelColor)
    private lazy var voicesButton = NSButton.push("Show…") { [weak self] in
        self?.presentSheet(VoicesSheetController())
    }

    private var engineRow: NSGridRow?
    private var engineLabelRow: NSGridRow?
    private var voiceRows: [NSGridRow] = []

    override func build() {
        let available = SpeechEngine.available
        engineRow = form.row("Default Model", enginePopUp)
        engineLabelRow = form.row("Default Model", engineLabel)
        engineRow?.isHidden = available.count <= 1
        engineLabelRow?.isHidden = available.count > 1

        var rows: [NSView] = []
        if available.contains(.apple) { rows.append(appleRow) }
        rows.append(parakeetRow)
        form.row("Models", NSStackView.vertical(rows, spacing: 12), top: true)
        form.row("Language", languagePopUp)
        form.row("Microphone", microphoneLabel)
        form.row("", recordsNewNotes)
        form.separator()
        form.row("Speakers", speakerRow, top: true)
        form.row("", detectSpeakers)
        voiceRows.append(form.row("", recognizeVoices))
        voiceRows.append(form.row("Known Voices", NSStackView.horizontal([voiceCount, voicesButton], spacing: 12)))

        libraryToken = Library.shared.observe { [weak self] in self?.setNeedsRender() }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        microphoneLabel.stringValue = AVCaptureDevice.default(for: .audio)?.localizedName ?? "Default Microphone"
        refreshASR()
    }

    override func render() {
        let defaults = UserDefaults.standard
        let engine = AppSettings.speechEngine
        let available = SpeechEngine.available
        enginePopUp.set(available.map(\.shortLabel), selected: available.firstIndex(of: engine))
        engineLabel.stringValue = engine.shortLabel

        appleRow.update(engine == .apple ? models.asr : .installed)
        parakeetRow.update(engine == .parakeet ? models.asr : models.spareParakeet)
        speakerRow.update(models.diarizer)

        let language = defaults.string(forKey: AppSettings.languageKey) ?? "auto"
        languagePopUp.set(AppSettings.languages.map(\.name), selected: AppSettings.languages.firstIndex { $0.code == language })
        if microphoneLabel.stringValue.isEmpty {
            microphoneLabel.stringValue = AVCaptureDevice.default(for: .audio)?.localizedName ?? "Default Microphone"
        }
        recordsNewNotes.isOn = defaults.bool(forKey: AppSettings.recordsNewNotesKey)

        let detection = defaults.bool(forKey: AppSettings.speakerDetectionKey)
        detectSpeakers.isOn = detection
        recognizeVoices.isOn = defaults.bool(forKey: AppSettings.voiceRecognitionKey)
        voiceCount.stringValue = "\((try? Library.shared.context.fetchCount(FetchDescriptor<VoiceProfile>())) ?? 0)"
        if voiceRows.first?.isHidden != !detection {
            voiceRows.forEach { $0.isHidden = !detection }
            contentChanged()
        }

        if let message = failures.newFailure(["asr": models.asr, "spare": models.spareParakeet, "diarizer": models.diarizer]) {
            Alerts.inform("Download Failed", message: message, in: view.window)
        }
    }

    private func refreshASR() {
        Task { await ModelManager.shared.refreshASR() }
    }

    private func confirmDelete(_ name: String, delete: @escaping @MainActor () async -> Void) {
        Alerts.confirm("Delete \(name)?", message: "You can download it again at any time.", action: "Delete", in: view.window) {
            Task { await delete() }
        }
    }
}
