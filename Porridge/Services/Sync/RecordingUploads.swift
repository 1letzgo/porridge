import Foundation

/// Recordings go up through the system's background session: iOS finishes an upload while the app is suspended or
/// gone, and with a long meeting on a slow line that is the normal case. Nothing waits for them. A finished upload
/// shows at the next sync as a file on the server, and one that failed is started again there.
final class RecordingUploads: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RecordingUploads()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: "de.letzgo.porridge.recordings")
        configuration.isDiscretionary = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// The recordings on their way up, also from before the app was restarted.
    func running() async -> Set<String> {
        Set(await session.allTasks.compactMap(\.taskDescription))
    }

    func start(_ request: URLRequest, file: URL, name: String) {
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = name
        task.resume()
    }

    /// A recording that was deleted must not arrive on the server afterwards.
    func cancel(_ names: Set<String>) async {
        for task in await session.allTasks where task.taskDescription.map(names.contains) == true {
            task.cancel()
        }
    }

    func cancelAll() async {
        for task in await session.allTasks { task.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if (error as? URLError)?.code == .cancelled { return }
        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let message: String?
        if let error {
            message = error.localizedDescription
        } else {
            message = (200...299).contains(code) ? nil : NextcloudError.http(code).localizedDescription
        }
        Task { @MainActor in NextcloudSync.shared.uploadFinished(error: message) }
    }
}
