import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// UI-facing state of the on-device models.
@MainActor
@Observable
final class ModelManager {
    static let shared = ModelManager()

    enum State: Equatable {
        case notInstalled
        case installed
        case downloading(Double)
        case loading
        case ready
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .loading: true
            default: false
            }
        }
    }

    private(set) var asr: State
    private(set) var diarizer: State
    /// On-device summary models.
    private(set) var llm: [LocalModel: State]

    private init() {
        asr = AppSettings.speechEngine == .parakeet && TranscriptionEngine.asrInstalled ? .installed : .notInstalled
        diarizer = TranscriptionEngine.diarizerInstalled ? .installed : .notInstalled
        llm = Dictionary(uniqueKeysWithValues: LocalModel.allCases.map { ($0, $0.isInstalled ? State.installed : .notInstalled) })
        Task { await refreshASR() }
    }

    /// Re-reads the state of the selected speech engine (after switching engine or language).
    func refreshASR() async {
        if asr.isBusy { return }
        switch AppSettings.speechEngine {
        case .parakeet:
            asr = TranscriptionEngine.asrInstalled ? .installed : .notInstalled
        case .apple:
            asr = await AppleSpeech.isInstalled(language: AppSettings.language) ? .ready : .notInstalled
        }
    }

    /// Makes sure recordings can be transcribed (always on the device).
    func ensureASR() async throws {
        try await ensureLocalASR()
    }

    /// Downloads (if needed) and loads the on-device speech model, whatever the transcription setting.
    func ensureLocalASR() async throws {
        if AppSettings.speechEngine == .apple { return try await ensureAppleSpeech() }
        if asr == .ready { return }
        asr = TranscriptionEngine.asrInstalled ? .loading : .downloading(0)
        do {
            _ = try await TranscriptionEngine.shared.loadASR { progress in
                Task { @MainActor in
                    let manager = ModelManager.shared
                    guard manager.asr != .ready else { return }
                    manager.asr = progress.fractionCompleted < 1
                        ? .downloading(progress.fractionCompleted)
                        : .loading
                }
            }
            asr = .ready
        } catch {
            asr = .failed(error.localizedDescription)
            throw error
        }
    }

    private func ensureAppleSpeech() async throws {
        if asr == .ready, await AppleSpeech.isInstalled(language: AppSettings.language) { return }
        asr = .downloading(0)
        do {
            try await AppleSpeech.install(language: AppSettings.language) { progress in
                Task { @MainActor in
                    let manager = ModelManager.shared
                    if case .downloading = manager.asr { manager.asr = .downloading(progress) }
                }
            }
            asr = .ready
        } catch {
            asr = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Looks at the files on disk again (e.g. when the settings are opened).
    func refreshLLM() {
        for model in LocalModel.allCases {
            switch llmState(model) {
            case .downloading, .loading, .ready: continue
            default: llm[model] = model.isInstalled ? .installed : .notInstalled
            }
        }
    }

    func llmState(_ model: LocalModel) -> State {
        llm[model] ?? .notInstalled
    }

    /// Downloads (if needed) and loads a summary model. Call `releaseLLM()` when done to free memory.
    func ensureLLM(_ model: LocalModel, onProgress: (@MainActor (Double) -> Void)? = nil) async throws {
        if llmState(model) == .ready { return }
        // A download stops when the screen locks; keep it on while the model is fetched.
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
        llm[model] = model.isInstalled ? .loading : .downloading(0)
        do {
            try await LocalLLM.shared.prepare(model) { fraction in
                Task { @MainActor in
                    let manager = ModelManager.shared
                    guard manager.llmState(model) != .ready else { return }
                    manager.llm[model] = fraction < 1 ? .downloading(fraction) : .loading
                    onProgress?(fraction)
                }
            }
            llm[model] = .ready
        } catch {
            print("[llm] \(model.rawValue) failed: \(error)")
            llm[model] = .failed(error.localizedDescription)
            throw error
        }
    }

    /// How many tasks (a summary, a chat answer) are using the summary model right now. It is not freed while
    /// somebody uses it: unloading it in the middle of a generation crashes the app.
    @ObservationIgnored private var llmUsers = 0
    @ObservationIgnored private var idleRelease: Task<Void, Never>?

    func beginLLMUse() {
        llmUsers += 1
        idleRelease?.cancel()
    }

    /// Ends one use; once nobody uses the model, it is freed after a short pause (a queue of summaries keeps it loaded).
    func endLLMUse() {
        llmUsers = max(0, llmUsers - 1)
        guard llmUsers == 0 else { return }
        idleRelease?.cancel()
        idleRelease = Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { await releaseLLM() }
        }
    }

    func releaseLLM() async {
        guard llmUsers == 0 else { return }
        await LocalLLM.shared.unload()
        for model in LocalModel.allCases where llmState(model) == .ready || llmState(model) == .loading {
            llm[model] = .installed
        }
    }

    /// Settings button: download the model, then free the memory again.
    func downloadLLM(_ model: LocalModel) async {
        try? await ensureLLM(model)
        await releaseLLM()
    }

    func deleteLLM(_ model: LocalModel) async {
        await LocalLLM.shared.delete(model)
        llm[model] = .notInstalled
    }

    /// Deletes the downloaded Parakeet model (the system's Apple Speech cannot be deleted here).
    func deleteASR() async {
        await TranscriptionEngine.shared.deleteASR()
        await refreshASR()
        if AppSettings.speechEngine == .parakeet { asr = .notInstalled }
    }

    func deleteDiarizer() async {
        await TranscriptionEngine.shared.deleteDiarizer()
        diarizer = .notInstalled
    }

    func ensureDiarizer() async throws {
        if diarizer == .ready { return }
        diarizer = TranscriptionEngine.diarizerInstalled ? .loading : .downloading(0)
        do {
            try await TranscriptionEngine.shared.loadDiarizer()
            diarizer = .ready
        } catch {
            diarizer = .failed(error.localizedDescription)
            throw error
        }
    }

    func prepareAll() async {
        try? await ensureASR()
        try? await ensureDiarizer()
    }
}
