import SwiftData
import SwiftUI

/// Bowls, the third place: every bowl (pinned first, then "All Bowls" in the order of Sort Bowls By, no limit),
/// then the smart filters with "New Smart Filter…", then Archive and Recently Deleted. The last three are always
/// there, "Empty" when they are. On an iPad (the sidebar has no tab bar) the other places come first.
struct BowlsPlace: View {
    let notes: [Note]
    let projects: [NoteFolder]
    let order: HomeList.BowlOrder
    /// The other places as the first section (iPad).
    var showsPlaces = false
    var onOpen: (ListPage) -> Void
    var onNewBowl: () -> Void
    var onRename: (NoteFolder) -> Void
    var onDelete: (NoteFolder) -> Void
    /// Select Entries from a bowl's long press: its page opens choosing.
    var onSelect: (NoteFolder) -> Void
    var onAsk: (NoteFolder) -> Void
    var onNewSmartFilter: () -> Void
    var onEditFilter: (SmartFilter) -> Void
    var onRenameFilter: (SmartFilter) -> Void
    var onDeleteFilter: (SmartFilter) -> Void

    var body: some View {
        let bowls = HomeList.bowls(projects, notes: notes, order: order)
        let pinned = bowls.filter(\.isPinned)
        let others = bowls.filter { !$0.isPinned }
        let contents = ProjectContent.byProject(notes)
        let archived = HomeList.archivedProjects(projects).count
        let deleted = notes.lazy.filter(\.isDeleted).count
        let filters = SmartFilterStore.shared.filters
        List {
            if showsPlaces {
                Section {
                    PlaceLinkRow(title: String(localized: "Today"), systemImage: "calendar", tint: .brandNavy, count: Places.todayCount(notes)) { onOpen(.today) }
                    PlaceLinkRow(title: String(localized: "Inbox"), systemImage: "tray.fill", tint: .brandSky, count: Places.inboxCount(notes)) { onOpen(.inbox) }
                    PlaceLinkRow(title: String(localized: "Chat"), systemImage: "bubble.left.and.bubble.right.fill", tint: .brandNavy) { onOpen(.chat) }
                    PlaceLinkRow(title: String(localized: "Search"), systemImage: "magnifyingglass", tint: .brandNavy) { onOpen(.search) }
                        .lastInSection(true)
                } header: {
                    ListHeader(title: String(localized: "Places"), tint: .brandNavy, isFirst: true)
                }
            }
            if bowls.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No Bowls Yet")
                            .font(.headline)
                        Text("A bowl holds everything about one topic.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button(action: onNewBowl) {
                            Label("New Bowl", systemImage: "folder.badge.plus")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.brandProject)
                        .accessibilityIdentifier("BowlsEmptyNewBowl")
                    }
                    .padding(.vertical, 6)
                    .cardListRow()
                    .lastInSection(true)
                } header: {
                    ListHeader(title: String(localized: "All Bowls"), tint: .brandProject, isFirst: !showsPlaces)
                }
            }
            if !pinned.isEmpty {
                CardSection {
                    rows(pinned, contents: contents)
                } header: {
                    ListHeader(title: String(localized: "Pinned"), tint: .brandProject, isFirst: !showsPlaces)
                }
            }
            if !others.isEmpty {
                CardSection {
                    rows(others, contents: contents)
                } header: {
                    ListHeader(
                        title: String(localized: "All Bowls"), tint: .brandProject, isFirst: pinned.isEmpty && !showsPlaces,
                        detail: String(localized: "by \(order.title)")
                    )
                }
            }
            // Saved searches: only views, nothing is moved into them.
            CardSection {
                ForEach(filters) { filter in
                    SmartFilterRow(
                        filter: filter, count: SmartFilters.results(filter.criteria, in: notes).count,
                        onOpen: { onOpen(.smartFilter(filter.id)) }, onEdit: { onEditFilter(filter) },
                        onRename: { onRenameFilter(filter) }, onDelete: { onDeleteFilter(filter) }
                    )
                }
                PlaceLinkRow(title: String(localized: "New Smart Filter…"), systemImage: "plus", tint: .brandNavy, showsChevron: false, action: onNewSmartFilter)
                    .lastInSection(true)
                    .accessibilityIdentifier("NewSmartFilter")
            } header: {
                ListHeader(title: String(localized: "Smart Filters"), tint: .brandNavy)
            }
            Section {
                PlaceLinkRow(
                    title: String(localized: "Archive"),
                    subtitle: archived == 0 ? String(localized: "Empty") : archived == 1 ? String(localized: "1 bowl") : String(localized: "\(archived) bowls"),
                    systemImage: "archivebox.fill", tint: .brandNavy, count: archived
                ) { onOpen(.archive) }
                .accessibilityIdentifier("BowlsArchive")
                PlaceLinkRow(
                    title: String(localized: "Recently Deleted"),
                    subtitle: deleted == 0 ? String(localized: "Empty")
                        : deleted == 1 ? String(localized: "1 entry · deleted after \(NoteStore.trashDays) days")
                        : String(localized: "\(deleted) entries · deleted after \(NoteStore.trashDays) days"),
                    systemImage: "trash.fill", tint: .red, count: deleted
                ) { onOpen(.trash) }
                .lastInSection(true)
                .accessibilityIdentifier("BowlsRecentlyDeleted")
            } header: {
                Rectangle().fill(Look.hairline).frame(height: 0.5)
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
            }
        }
        .cardList()
    }

    private func rows(_ bowls: [NoteFolder], contents: [String: ProjectContent]) -> some View {
        ForEach(bowls) { project in
            ProjectRow(
                project: project,
                content: contents[Projects.key(project)] ?? ProjectContent(),
                onOpen: { onOpen(.project(project.id)) },
                onRename: { onRename(project) },
                onDelete: { onDelete(project) },
                onAsk: { onAsk(project) },
                onSelect: { onSelect(project) }
            )
            .lastInSection(project.id == bowls.last?.id)
        }
    }
}

/// A fixed row that leads somewhere (Archive, Recently Deleted, Open To-dos, Weekly Review, New Smart Filter…): a
/// symbol in its color, the name, a line about what is there and how many.
struct PlaceLinkRow: View {
    let title: String
    var subtitle: String?
    let systemImage: String
    let tint: Color
    var count: Int?
    var showsChevron = true
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            // With the largest text sizes the row is tall: the icon stays by the first line.
            HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
                ThingsRowIcon(systemImage: systemImage, tint: tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardListRow()
    }
}
