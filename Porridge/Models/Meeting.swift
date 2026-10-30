import Foundation
import SwiftData

/// The former meeting type. Meetings are notes now; these records are only read once to copy them into notes
/// (see `LegacyMigration`) and are kept as a backup. CloudKit-compatible: every property has a default.
@Model
final class Meeting {
    var id: UUID = UUID()
    var title: String = ""
    var titleIsCustom: Bool = false
    var createdAt: Date = Date()
    var duration: Double = 0
    var statusRaw: String = ProcessingStatus.recorded.rawValue
    var errorMessage: String?
    var inputName: String?
    var channelCount: Int = 1
    var speakerModeRaw: String = SpeakerMode.none.rawValue
    var audioFileName: String?
    var speakersData: Data?
    var segmentsData: Data?
    var summary: String?
    var summaryModel: String?
    var summarizedAt: Date?

    /// Set once the meeting has been copied into a note (see `LegacyMigration`).
    var migrated: Bool = false

    init() {}
}
