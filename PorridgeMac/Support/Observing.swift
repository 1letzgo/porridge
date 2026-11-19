import Foundation
import Observation

/// Runs a closure now and again whenever an `@Observable` value it read changes: the AppKit side of the
/// `@Observable` services (`ProcessingService`, `ModelManager`, the `@Model` notes). The closure runs on the
/// main actor, a moment after the change (the change is announced before it is made).
@MainActor
final class Observing {
    private var body: (@MainActor () -> Void)?
    private var scheduled = false

    init(_ body: @escaping @MainActor () -> Void) {
        self.body = body
        run()
    }

    private func run() {
        guard let body else { return }
        withObservationTracking {
            body()
        } onChange: { [weak self] in
            Task { @MainActor in self?.again() }
        }
    }

    private func again() {
        guard body != nil else { return }
        run()
    }

    /// Stops following; the closure is not called again.
    func cancel() {
        body = nil
    }

    deinit {}
}

extension Array where Element == Observing {
    @MainActor mutating func cancelAll() {
        forEach { $0.cancel() }
        removeAll()
    }
}
