import Foundation
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

/// iOS refuses the GPU to an app in the background, and suspends it soon after anyway. Work that needs either
/// waits here until the app is back, instead of failing, so a long summary keeps the parts it already has.
@MainActor
enum ForegroundWork {
    /// A running `ContinuedSummaryTask` lets the GPU work go on in the background.
    static var mayRunInBackground = false

    static var isAllowed: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState != .background || mayRunInBackground
        #else
        true
        #endif
    }

    static func waitUntilAllowed() async {
        while !isAllowed { try? await Task.sleep(for: .seconds(1)) }
    }

    /// Runs `work` again when going to the background made it fail. Other errors are real and are passed on.
    nonisolated static func retrying<T>(
        waitsFirst: Bool = true,
        isolation: isolated (any Actor)? = #isolation,
        _ work: () async throws -> T
    ) async throws -> T {
        var waits = waitsFirst
        while true {
            if waits { await waitUntilAllowed() }
            await observeBackground()
            let started = Date()
            do {
                return try await work()
            } catch {
                guard await wentToBackground(since: started), !Task.isCancelled else { throw error }
                waits = true
            }
        }
    }

    private static var lastBackground: Date?
    private static var observer: NSObjectProtocol?

    private static func observeBackground() {
        #if os(iOS)
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { lastBackground = Date() }
        }
        #endif
    }

    private static func wentToBackground(since start: Date) -> Bool {
        guard !mayRunInBackground else { return !isAllowed }
        return !isAllowed || (lastBackground.map { $0 >= start } ?? false)
    }
}

#if os(iOS)
/// Asks iOS to let a summary the user started go on in the background, with the system's own progress display.
/// Needs a device with background GPU support; without one the summary simply waits (see `ForegroundWork`).
@available(iOS 26, *)
@MainActor
final class ContinuedSummaryTask {
    private var task: BGContinuedProcessingTask?
    private var isFinished = false
    private var ticker: Task<Void, Never>?
    private let title: String

    private init(title: String) { self.title = title }

    /// Must be called while the app is in the foreground; returns nil when iOS does not run it.
    static func begin(title: String, subtitle: String) -> ContinuedSummaryTask? {
        guard BGTaskScheduler.supportedResources.contains(.gpu) else { return nil }
        let work = ContinuedSummaryTask(title: title)
        let identifier = "de.letzgo.porridge.summary.\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            MainActor.assumeIsolated { work.started(task) }
        }
        guard registered else { return nil }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        request.requiredResources = .gpu
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[summary] no background time: \(error)")
            return nil
        }
        return work
    }

    private func started(_ task: BGContinuedProcessingTask) {
        guard !isFinished else {
            task.setTaskCompleted(success: true)
            return
        }
        self.task = task
        ForegroundWork.mayRunInBackground = true
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.end(success: false) }
        }
        // iOS ends a task that reports no progress, and one answer of the model can take minutes.
        task.progress.totalUnitCount = 100
        ticker = Task { [weak task] in
            while !Task.isCancelled, let progress = task?.progress {
                progress.completedUnitCount = min(95, progress.completedUnitCount + 1)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func update(_ status: String) {
        task?.updateTitle(title, subtitle: status)
    }

    func end(success: Bool) {
        isFinished = true
        ticker?.cancel()
        ForegroundWork.mayRunInBackground = false
        task?.setTaskCompleted(success: success)
        task = nil
    }
}
#endif
