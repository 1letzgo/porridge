import SwiftUI

/// The filter by tag as a drop-down in the bar: all, every tag with its count and, where notes are listed,
/// "Recently Deleted". The same menu in tasks, meetings, notes and links.
struct TagMenu: View {
    /// The notes of the view, for the tags and their counts.
    let notes: [Note]
    @Binding var scope: NoteScope
    /// Offer "Recently Deleted" (notes and meetings).
    var showsTrash = false
    /// How many notes are in "Recently Deleted".
    var deletedCount = 0
    /// Color of the button while a tag is chosen (the view's color).
    var tint: Color = .brandSky

    var body: some View {
        let tags = Self.tagCounts(notes.filter { !$0.isDeleted })
        Menu {
            item("All", "tray.full", nil, .all)
            if !tags.isEmpty {
                Divider()
                ForEach(tags, id: \.key) { tag in
                    item("#" + tag.name, "number", tag.count, .tag(tag.key))
                }
            }
            if showsTrash {
                Divider()
                item("Recently Deleted", "trash", deletedCount, .trash)
            }
        } label: {
            Label("Tags", systemImage: isFiltered ? "number.square.fill" : "number")
        }
        #if os(iOS)
        // A chosen tag fills the button with the view's color, so an active filter is seen at a glance.
        .buttonStyle(ChromePillButtonStyle(fill: isFiltered ? tint : nil))
        #endif
        .accessibilityLabel("Filter by Tag")
        .accessibilityValue(isFiltered ? "Active" : "Off")
    }

    private var isFiltered: Bool {
        if case .tag = scope { return true }
        return false
    }

    private func item(_ title: String, _ systemImage: String, _ count: Int?, _ target: NoteScope) -> some View {
        Button {
            scope = target
        } label: {
            Label(count.map { "\(title) (\($0))" } ?? title, systemImage: scope == target ? "checkmark" : systemImage)
        }
    }

    static func tagCounts(_ active: [Note]) -> [(key: String, name: String, count: Int)] {
        var order: [String] = []
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        for note in active {
            for tag in note.tags {
                let key = tag.lowercased()
                if names[key] == nil { names[key] = tag; order.append(key) }
                counts[key, default: 0] += 1
            }
        }
        return order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { (key: $0, name: names[$0]!, count: counts[$0]!) }
    }
}
