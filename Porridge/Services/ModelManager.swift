import Foundation
import HuggingFace
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
            asr = Self.isCancellation(error) ? .notInstalled : .failed(error.localizedDescription)
            throw error
        }
    }

    /// The user stopped the download: nothing went wrong.
    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
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
        llm[model] = model.isInstalled ? .loading : .downloading(0)
        do {
            #if os(iOS)
            if !model.isInstalled {
                try await fetchInBackground(model, onProgress: onProgress)
                // The rest of the way uses the GPU, which iOS refuses to an app in the background.
                while UIApplication.shared.applicationState != .active {
                    try await Task.sleep(for: .seconds(1))
                }
            }
            #endif
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
            llm[model] = Self.isCancellation(error) ? .notInstalled : .failed(error.localizedDescription)
            throw error
        }
    }

    #if os(iOS)
    /// Fetches the weights with the system's background downloads. `LocalLLM` then finds them in its cache and only
    /// adds the small files, so a download goes on with the app in the background or even ended by iOS.
    private func fetchInBackground(_ model: LocalModel, onProgress: (@MainActor (Double) -> Void)?) async throws {
        guard let repo = Repo.ID(rawValue: model.repoID) else { throw LocalLLMError.invalidModelID(model.repoID) }
        let cache = HubCache(cacheDirectory: model.cacheDirectory)
        let entries = try await HubClient(cache: cache).listFiles(in: repo)
        let files: [ModelBackgroundDownloads.File] = try entries.compactMap { entry in
            guard entry.path.hasSuffix(".safetensors"), let lfs = entry.lfs, let etag = lfs.oid,
                  let url = URL(string: "https://huggingface.co/\(model.repoID)/resolve/main/\(entry.path)")
            else { return nil }
            return .init(url: url, destination: try cache.blobPath(repo: repo, kind: .model, etag: etag), bytes: Int64(lfs.size))
        }
        try await ModelBackgroundDownloads.shared.fetch(files, group: model.rawValue) { fraction in
            Task { @MainActor in
                let manager = ModelManager.shared
                guard case .downloading = manager.llmState(model) else { return }
                manager.llm[model] = .downloading(fraction)
                onProgress?(fraction)
            }
        }
    }

    /// Core ML compiles a model anew for every installation of the app and leaves the old copies behind, over 1 GB
    /// each. Every installation has its own bundle path, so a new path means nothing in the cache is of use any more.
    /// Runs before any model is loaded.
    nonisolated static func clearCompiledModelsAfterUpdate() async {
        let key = "compiledModelsInstallation"
        let installation = Bundle.main.bundlePath
        guard UserDefaults.standard.string(forKey: key) != installation else { return }
        await Task.detached(priority: .utility) {
            guard let identifier = Bundle.main.bundleIdentifier else { return }
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(identifier, isDirectory: true)
                .appendingPathComponent("com.apple.e5rt.e5bundlecache", isDirectory: true)
            try? FileManager.default.removeItem(at: cache)
        }.value
        UserDefaults.standard.set(installation, forKey: key)
    }

    /// iOS may have ended the app while a download ran on: show it again, and finish it once it is done.
    func resumeBackgroundDownloads() async {
        for group in await ModelBackgroundDownloads.shared.runningGroups() {
            guard let model = LocalModel(rawValue: group), llmState(model) != .ready else { continue }
            Task { await downloadLLM(model) }
        }
    }
    #endif

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
        #if os(iOS)
        await ModelBackgroundDownloads.shared.cancel(group: model.rawValue)
        #endif
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

#if os(iOS)
private extension LocalModel {
    /// The folder `LocalLLM` keeps this model's cache in.
    var cacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models/LLM/\(rawValue)", isDirectory: true)
    }
}

/// Downloads that iOS carries out itself: they go on while the app is suspended or was ended by the system.
/// Each task names its file in `taskDescription`, because after a restart that is all that is left of it.
final class ModelBackgroundDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = ModelBackgroundDownloads()

    struct File: Sendable {
        let url: URL
        let destination: URL
        let bytes: Int64
    }

    /// What a task is fetching. The path is relative, since an app update moves the app's container.
    private struct Ticket: Codable {
        let group: String
        let path: String
        let bytes: Int64

        var destination: URL { Self.base.appendingPathComponent(path) }
        static var base: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    }

    /// The people waiting for one model's files.
    private struct Waiting {
        var pending: Set<String>
        var files: [String: File]
        var finishedBytes: Int64
        let totalBytes: Int64
        var continuations: [CheckedContinuation<Void, Error>] = []
        var progress: [@Sendable (Double) -> Void] = []
    }

    /// Set by the app delegate when iOS wakes the app for finished downloads.
    var backgroundCompletion: (() -> Void)? {
        get { lock.withLock { completion } }
        set { lock.withLock { completion = newValue }; _ = session }
    }

    private let lock = NSLock()
    private var completion: (() -> Void)?
    private var waiting: [String: Waiting] = [:]
    private var tickets: [Int: Ticket] = [:]
    private var received: [Int: Int64] = [:]
    private var attempts: [String: Int] = [:]
    /// Tasks whose file has reached its place; their end needs no retry.
    private var stored: Set<Int> = []
    private var cancelled: Set<String> = []
    private static let maxAttempts = 5

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "de.letzgo.porridge.model-downloads")
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// Returns once all files are in place. A task that is already running from before is joined, not started again.
    func fetch(_ files: [File], group: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let manager = FileManager.default
        let missing = files.filter { !manager.fileExists(atPath: $0.destination.path) }
        guard !missing.isEmpty else { return }
        let running = await session.allTasks.compactMap { ticket(for: $0)?.path }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var start: [(String, File)] = []
            lock.withLock {
                cancelled.remove(group)
                var entry = waiting[group] ?? Waiting(
                    pending: [], files: [:],
                    finishedBytes: files.reduce(0) { $0 + $1.bytes } - missing.reduce(0) { $0 + $1.bytes },
                    totalBytes: files.reduce(0) { $0 + $1.bytes }
                )
                for file in missing where !manager.fileExists(atPath: file.destination.path) {
                    let path = Self.relativePath(file.destination)
                    entry.files[path] = file
                    guard !entry.pending.contains(path) else { continue }
                    entry.pending.insert(path)
                    attempts[path] = 0
                    if !running.contains(path) { start.append((path, file)) }
                }
                guard !entry.pending.isEmpty else {
                    waiting[group] = nil
                    continuation.resume()
                    return
                }
                entry.continuations.append(continuation)
                entry.progress.append(progress)
                waiting[group] = entry
            }
            for (path, file) in start { self.start(file, path: path, group: group) }
        }
    }

    /// The models with a download under way, e.g. from before the app was ended.
    func runningGroups() async -> Set<String> {
        Set(await session.allTasks.compactMap { ticket(for: $0)?.group })
    }

    /// Stops a model's downloads for good, together with what is kept for resuming them.
    func cancel(group: String) async {
        let waiters: [CheckedContinuation<Void, Error>] = lock.withLock {
            cancelled.insert(group)
            return waiting.removeValue(forKey: group)?.continuations ?? []
        }
        for task in await session.allTasks {
            guard let ticket = ticket(for: task), ticket.group == group else { continue }
            task.cancel()
            try? FileManager.default.removeItem(at: Self.resumeFile(for: ticket.path))
        }
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
    }

    private func start(_ file: File, path: String, group: String) {
        let resumeFile = Self.resumeFile(for: path)
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeFile) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: file.url)
        }
        let ticket = Ticket(group: group, path: path, bytes: file.bytes)
        task.taskDescription = (try? JSONEncoder().encode(ticket)).flatMap { String(data: $0, encoding: .utf8) }
        task.countOfBytesClientExpectsToReceive = file.bytes
        lock.withLock { tickets[task.taskIdentifier] = ticket }
        task.resume()
    }

    private func ticket(for task: URLSessionTask) -> Ticket? {
        lock.withLock {
            if let known = tickets[task.taskIdentifier] { return known }
            guard let data = task.taskDescription?.data(using: .utf8),
                  let ticket = try? JSONDecoder().decode(Ticket.self, from: data) else { return nil }
            tickets[task.taskIdentifier] = ticket
            return ticket
        }
    }

    private static func relativePath(_ url: URL) -> String {
        String(url.path.dropFirst(Ticket.base.path.count + 1))
    }

    /// Caches, not the model's folder: losing it only means starting that file again.
    private static func resumeFile(for path: String) -> URL {
        let name = (path as NSString).lastPathComponent
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("model-download-\(name).resume")
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let ticket = ticket(for: downloadTask) else { return }
        let (fraction, handlers): (Double, [@Sendable (Double) -> Void]) = lock.withLock {
            received[downloadTask.taskIdentifier] = totalBytesWritten
            guard let entry = waiting[ticket.group], entry.totalBytes > 0 else { return (0, []) }
            let running = tickets.filter { $0.value.group == ticket.group }.keys.reduce(Int64(0)) { $0 + (received[$1] ?? 0) }
            return (min(Double(entry.finishedBytes + running) / Double(entry.totalBytes), 1), entry.progress)
        }
        for handler in handlers { handler(fraction) }
    }

    /// The file is gone when this returns, so it is moved right here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let ticket = ticket(for: downloadTask) else { return }
        // An error page arrives as a finished download too.
        guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { return }
        let manager = FileManager.default
        let size = (try? manager.attributesOfItem(atPath: location.path))?[.size] as? Int64
        guard size == ticket.bytes else { return }
        let target = ticket.destination
        try? manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.removeItem(at: target)
        guard (try? manager.moveItem(at: location, to: target)) != nil else { return }
        lock.withLock { _ = stored.insert(downloadTask.taskIdentifier) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let ticket = ticket(for: task) else { return }
        let id = task.taskIdentifier
        let (isStored, isCancelled): (Bool, Bool) = lock.withLock {
            tickets[id] = nil
            received[id] = nil
            return (stored.remove(id) != nil, cancelled.contains(ticket.group))
        }
        let resumeFile = Self.resumeFile(for: ticket.path)
        if isStored {
            try? FileManager.default.removeItem(at: resumeFile)
            finished(ticket)
            return
        }
        if isCancelled { return }

        // Keep what has arrived; without anything to resume from, a stale file must not get in the way.
        let info = (error as NSError?)?.userInfo
        if let data = info?[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: resumeFile, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: resumeFile)
        }
        // Ended from the app switcher: the user meant it, and the file continues with the next download.
        let reason = info?[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int
        let forceQuit = reason == NSURLErrorCancelledReasonUserForceQuitApplication
        let (file, attempt): (File?, Int) = lock.withLock {
            let attempt = (attempts[ticket.path] ?? 0) + 1
            attempts[ticket.path] = attempt
            return (waiting[ticket.group]?.files[ticket.path], attempt)
        }
        guard let file, !forceQuit, attempt <= Self.maxAttempts else {
            print("[llm] background download of \(ticket.path) failed: \(String(describing: error))")
            failed(ticket, error: error ?? URLError(.badServerResponse))
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(5 * attempt)) {
            self.start(file, path: ticket.path, group: ticket.group)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock {
            defer { completion = nil }
            return completion
        }
        DispatchQueue.main.async { handler?() }
    }

    private func finished(_ ticket: Ticket) {
        let waiters: [CheckedContinuation<Void, Error>] = lock.withLock {
            guard var entry = waiting[ticket.group] else { return [] }
            entry.pending.remove(ticket.path)
            entry.finishedBytes += ticket.bytes
            guard entry.pending.isEmpty else {
                waiting[ticket.group] = entry
                return []
            }
            waiting[ticket.group] = nil
            return entry.continuations
        }
        for waiter in waiters { waiter.resume() }
    }

    private func failed(_ ticket: Ticket, error: Error) {
        let waiters = lock.withLock { waiting.removeValue(forKey: ticket.group)?.continuations ?? [] }
        for waiter in waiters { waiter.resume(throwing: error) }
    }
}
#endif
