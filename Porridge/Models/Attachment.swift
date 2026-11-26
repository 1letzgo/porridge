import Foundation

/// The channel a note came in through. Everything that enters the app is an intake that lands in the inbox.
enum NoteSource: String {
    /// From before there were channels.
    case unknown = ""
    case note
    case meeting
    case link
    /// Shared into the app from another one, or dropped onto it.
    case share
    /// An audio file brought in from outside.
    case audioImport = "import"

    var label: String {
        switch self {
        case .unknown, .note: "Note"
        case .meeting: "Meeting"
        case .link: "Link"
        case .share: "Shared"
        case .audioImport: "Import"
        }
    }
}

/// A file that belongs to a note. It lives in the same store as the recordings (`AudioStore`) and, like them,
/// goes to the other devices through iCloud Drive when sync is on; the note's list of attachments syncs.
struct Attachment: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case image
        case pdf
        case file
    }

    var id: String = UUID().uuidString
    /// Name in the store.
    var fileName: String
    /// What the file was called where it came from.
    var name: String
    var kindRaw: String
    var bytes: Int64 = 0
    /// What the file is as a document (kind, date, sender, amount); nil until it was read. Inside the synced list of
    /// attachments, so it needs no field of its own in the store; older versions ignore it.
    var document: DocumentInfo?

    var kind: Kind { Kind(rawValue: kindRaw) ?? .file }

    /// Sorted keys, so the same attachments are the same bytes on every device (the sync compares them).
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
