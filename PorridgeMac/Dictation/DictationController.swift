import AppKit
import AVFoundation
import Observation

/// Dictation anywhere on the Mac: hold the shortcut, speak, let go, and the text is typed into the
/// app you are in. Everything runs on this Mac.
@MainActor
@Observable
final class DictationController {
    static let shared = DictationController()

    enum State: Equatable {
        case idle
        case recording
        case transcribing
        /// A short notice that disappears by itself (an error or a hint).
        case message(String)
    }

    private(set) var state: State = .idle
    /// The shortcut could not be registered (another app uses it).
    private(set) var shortcutUnavailable = false
    /// The shortcut is a modifier key on its own, which can only be watched with the Accessibility permission.
    private(set) var shortcutNeedsAccessibility = false
    let recorder = AudioRecorder()

    @ObservationIgnored private let hotKey = GlobalHotKey()
    @ObservationIgnored private let modifierKey = ModifierKeyMonitor()
    @ObservationIgnored private var permissionWatch: Task<Void, Never>?
    @ObservationIgnored private var keyIsDown = false
    @ObservationIgnored private var messageTask: Task<Void, Never>?

    private init() {
        hotKey.onPress = { [weak self] in self?.shortcutPressed() }
        hotKey.onRelease = { [weak self] in self?.shortcutReleased() }
        modifierKey.onPress = { [weak self] in self?.shortcutPressed() }
        modifierKey.onRelease = { [weak self] in self?.shortcutReleased() }
        recorder.onInterrupted = { [weak self] in self?.stopAndTranscribe() }
    }

    /// Registers the shortcut from the settings. Call again after they change.
    func reloadShortcut() {
        hotKey.unregister()
        modifierKey.stop()
        permissionWatch?.cancel()
        shortcutUnavailable = false
        shortcutNeedsAccessibility = false
        guard DictationSettings.enabled else { return }
        if DictationSettings.isModifierOnly {
            guard ModifierKeyMonitor.hasPermission else {
                shortcutNeedsAccessibility = true
                watchForPermission()
                return
            }
            shortcutUnavailable = !modifierKey.start(keyCode: Int(DictationSettings.keyCode))
        } else {
            shortcutUnavailable = !hotKey.register(keyCode: DictationSettings.keyCode, modifiers: DictationSettings.modifiers)
        }
    }

    /// The permission is given in System Settings, outside the app: look every few seconds and start
    /// the shortcut as soon as it is there.
    private func watchForPermission() {
        permissionWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                if ModifierKeyMonitor.hasPermission {
                    self.reloadShortcut()
                    return
                }
            }
        }
    }

    var isRecording: Bool { state == .recording }

    /// From the menu bar: the same as pressing the shortcut in toggle mode.
    func toggleFromMenu() {
        if state == .recording { stopAndTranscribe() } else { startRecording() }
    }

    // MARK: - Shortcut

    private func shortcutPressed() {
        keyIsDown = true
        switch DictationSettings.mode {
        case .hold:
            startRecording()
        case .toggle:
            if state == .recording { stopAndTranscribe() } else { startRecording() }
        }
    }

    private func shortcutReleased() {
        keyIsDown = false
        if DictationSettings.mode == .hold, state == .recording { stopAndTranscribe() }
    }

    // MARK: - Recording

    private func startRecording() {
        guard state == .idle || isMessage else { return }
        messageTask?.cancel()
        Task {
            guard await AudioRecorder.requestPermission() else {
                show("Microphone access is off. Allow it in System Settings → Privacy & Security → Microphone.")
                return
            }
            do {
                try recorder.start()
            } catch {
                show(error.localizedDescription)
                return
            }
            set(.recording)
            play("Tink")
            // Released while the permission was being checked.
            if DictationSettings.mode == .hold, !keyIsDown { stopAndTranscribe() }
        }
    }

    private var isMessage: Bool {
        if case .message = state { return true }
        return false
    }

    private func stopAndTranscribe() {
        guard state == .recording, let result = recorder.stop() else { return }
        play("Pop")
        // A tap on the shortcut is not a dictation.
        guard result.duration >= 0.4 else {
            AudioStore.delete(result.fileName)
            set(.idle)
            return
        }
        set(.transcribing)
        Task { await transcribeAndInsert(result) }
    }

    private func transcribeAndInsert(_ result: RecordingResult) async {
        defer { AudioStore.delete(result.fileName) }
        do {
            let source = AudioStore.url(for: result.fileName)
            let prepared = try await Task.detached(priority: .userInitiated) {
                try AudioPreprocessor.prepare(source: source, measureChannels: false)
            }.value
            defer { try? FileManager.default.removeItem(at: prepared.monoURL) }

            try await ModelManager.shared.ensureASR()
            let output = try await TranscriptionEngine.shared.transcribe(prepared.monoURL, language: AppSettings.language)
            let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                show("No speech detected.")
                return
            }
            if await TextInserter.insert(text) {
                set(.idle)
            } else {
                TextInserter.requestAccess()
                show("Copied. Press ⌘V to paste. Allow Accessibility in System Settings to paste automatically.", seconds: 5)
            }
        } catch {
            show(error.localizedDescription)
        }
    }

    // MARK: - State

    private func set(_ new: State) {
        state = new
        switch new {
        case .idle: DictationOverlay.shared.hide()
        default: DictationOverlay.shared.show(controller: self)
        }
    }

    private func show(_ message: String, seconds: Double = 3) {
        messageTask?.cancel()
        set(.message(message))
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.isMessage else { return }
            self.set(.idle)
        }
    }

    private func play(_ name: String) {
        guard DictationSettings.sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
