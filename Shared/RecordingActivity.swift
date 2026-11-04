import Foundation
#if os(iOS)
import ActivityKit
import AppIntents

/// Live Activity shown on the Lock Screen and in the Dynamic Island while Porridge records.
struct RecordingActivityAttributes: ActivityAttributes {
    enum Kind: String, Codable, Hashable {
        case meeting
        case note
    }

    struct ContentState: Codable, Hashable {
        /// When the recording started; the widget counts up from here without updates.
        var startedAt: Date
        /// Set while the recording is paused; the widget's clock stands still at this moment.
        var pausedAt: Date?
        var isFinishing = false
    }

    var kind: Kind
    var title: String
}
#endif

extension Notification.Name {
    /// Posted when the user taps "Stop" in the Live Activity.
    static let porridgeStopRecording = Notification.Name("de.letzgo.porridge.stopRecording")
}

/// Registered by the app while a recording runs, so the Live Activity's buttons do not depend on any view still being on screen.
@MainActor
enum RecordingCenter {
    static var stop: (() -> Void)?
    /// Only meetings can pause.
    static var togglePause: (() -> Void)?
}

#if os(iOS)
/// "Stop" button of the Live Activity. Runs inside the app process.
struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let isDiscoverable = false
    /// Works from the Lock Screen without unlocking the phone first.
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    func perform() async throws -> some IntentResult {
        let handled = await MainActor.run { () -> Bool in
            guard let stop = RecordingCenter.stop else { return false }
            stop()
            return true
        }
        if !handled { await endLeftoverActivities() }
        return .result()
    }
}

/// "Pause" / "Resume" button of the Live Activity. Runs inside the app process.
struct PauseRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause or Resume Recording"
    static let isDiscoverable = false
    /// Works from the Lock Screen without unlocking the phone first.
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    func perform() async throws -> some IntentResult {
        let handled = await MainActor.run { () -> Bool in
            guard let togglePause = RecordingCenter.togglePause else { return false }
            togglePause()
            return true
        }
        if !handled { await endLeftoverActivities() }
        return .result()
    }
}

/// Nothing is recording any more (e.g. the app was restarted): don't leave dead buttons behind.
private func endLeftoverActivities() async {
    for activity in Activity<RecordingActivityAttributes>.activities {
        await activity.end(nil, dismissalPolicy: .immediate)
    }
}
#endif
