import Foundation

/// Links shared from other apps wait here until Porridge picks them up. The share sheet extension only writes a small
/// file; the app turns the files into notes (see `LinkImport`).
enum LinkInbox {
    static let groupID = "group.de.letzgo.porridge"

    struct Entry: Codable {
        var url: String
        var title: String?
        var date: Date
    }

    private static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("LinkInbox", isDirectory: true)
    }

    static func add(_ entry: Entry) throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entry)
        try data.write(to: directory.appendingPathComponent("\(UUID().uuidString).json"), options: .atomic)
    }

    /// Takes everything out of the inbox, oldest first.
    static func drain() -> [Entry] {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var entries: [Entry] = []
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(Entry.self, from: data) {
                entries.append(entry)
            }
            try? FileManager.default.removeItem(at: file)
        }
        return entries.sorted { $0.date < $1.date }
    }
}
