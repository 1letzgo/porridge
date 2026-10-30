#if os(iOS)
import ActivityKit
import Foundation

/// Starts and ends the Live Activity (Lock Screen + Dynamic Island) while recording.
@MainActor
enum LiveRecording {
    private static var activity: Activity<RecordingActivityAttributes>?

    /// `onStop` runs when the user taps "Stop" in the Live Activity.
    static func start(kind: RecordingActivityAttributes.Kind, title: String, startedAt: Date = Date(), onStop: @escaping () -> Void) {
        RecordingCenter.stop = onStop
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endActivity()
        let attributes = RecordingActivityAttributes(kind: kind, title: title)
        let state = RecordingActivityAttributes.ContentState(startedAt: startedAt)
        activity = try? Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
    }

    /// Recording stopped, the last part is still being processed.
    static func markFinishing() {
        guard let activity else { return }
        var state = activity.content.state
        state.isFinishing = true
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    static func end() {
        RecordingCenter.stop = nil
        endActivity()
    }

    /// Ends activities left behind by an earlier run (app killed while recording).
    static func endStale() {
        guard RecordingCenter.stop == nil else { return }
        for activity in Activity<RecordingActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private static func endActivity() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
#else
import Foundation

/// The Mac has no Live Activities; only the stop hook is kept.
@MainActor
enum LiveRecording {
    enum Kind {
        case meeting
        case note
    }

    static func start(kind: Kind, title: String, startedAt: Date = Date(), onStop: @escaping () -> Void) {
        RecordingCenter.stop = onStop
    }

    static func markFinishing() {}

    static func end() {
        RecordingCenter.stop = nil
    }

    static func endStale() {}
}
#endif
