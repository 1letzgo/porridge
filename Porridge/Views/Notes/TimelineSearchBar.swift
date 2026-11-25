import SwiftUI

/// A tag as a chip in the search field.
struct TagToken: Identifiable, Hashable {
    let name: String
    var id: String { name.lowercased() }

    /// The tags of the notes with how many notes have them, by name.
    static func counts(_ notes: [Note]) -> [(key: String, name: String, count: Int)] {
        var order: [String] = []
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        for note in notes {
            for tag in note.tags {
                let key = tag.lowercased()
                if names[key] == nil { names[key] = tag; order.append(key) }
                counts[key, default: 0] += 1
            }
        }
        return order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { (key: $0, name: names[$0]!, count: counts[$0]!) }
    }
}

/// The kinds of elements the search can be narrowed to.
enum SearchKind: CaseIterable {
    case todos, meetings, notes, links, images, files

    var title: LocalizedStringKey {
        switch self {
        case .todos: "Open To-dos"
        case .meetings: "Meetings"
        case .notes: "Notes"
        case .links: "Links"
        case .images: "Images"
        case .files: "Files"
        }
    }

    /// The title as a string (VoiceOver's value of the kind menu).
    var name: String {
        switch self {
        case .todos: String(localized: "Open To-dos")
        case .meetings: String(localized: "Meetings")
        case .notes: String(localized: "Notes")
        case .links: String(localized: "Links")
        case .images: String(localized: "Images")
        case .files: String(localized: "Files")
        }
    }

    func matches(_ note: Note) -> Bool {
        switch self {
        case .todos: note.isTodo && !note.isDone
        case .meetings: note.isRecording && !note.isLink
        case .notes: !note.isRecording && !note.isLink && !note.isStored && !note.isTodo
        case .links: note.isLink
        case .images: note.isImage
        case .files: note.isFile
        }
    }
}

/// Search & Ask: a field, where it looks (Everywhere, the Inbox, a bowl) and the kinds as chips, the tags that fit
/// what is typed, and what matches below (`results`: "Ask Porridge: …", Go To, the entries). The empty field shows
/// the recent searches and the tags.
struct SearchPane<Results: View>: View {
    @Binding var text: String
    @Binding var tokens: [TagToken]
    @Binding var kind: SearchKind?
    @Binding var scope: SearchAsk.Scope
    /// The bowls to look in (active ones, in the order of the Bowls place).
    let bowls: [NoteFolder]
    /// Every bowl, for the name of the chosen one.
    let allBowls: [NoteFolder]
    let tags: [(key: String, name: String, count: Int)]
    let hasQuery: Bool
    var recentSearches: [String] = []
    var onRecent: (String) -> Void = { _ in }
    var onClearRecent: () -> Void = {}
    /// Return in the field: what was typed is kept as a recent search (it never asks the chat).
    var onSubmit: () -> Void = {}
    @ViewBuilder var results: Results

    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    private var openTags: [(key: String, name: String, count: Int)] {
        let taken = Set(tokens.map(\.id))
        return tags.filter { !taken.contains($0.key) }
    }

    /// Tags that fit what is typed.
    private var matchingTags: [(key: String, name: String, count: Int)] {
        let typed = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !typed.isEmpty else { return [] }
        return openTags.filter { $0.name.localizedCaseInsensitiveContains(typed) }
    }

    var body: some View {
        VStack(spacing: 10) {
            field
                .padding(.horizontal)

            if typeSize.isAccessibilitySize {
                // The largest text sizes: two chips that wrap (the kinds in one menu), nothing cut off at the edge.
                FlowLayout(spacing: 8) {
                    scopeChip
                    kindMenuChip
                }
                .padding(.horizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        scopeChip
                        ForEach(SearchKind.allCases, id: \.self) { option in kindChip(option) }
                    }
                    .padding(.horizontal)
                }
            }

            if !matchingTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(matchingTags.prefix(20), id: \.key) { tag in chip(tag) }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 2)
                }
            }

            if hasQuery {
                // The keyboard goes with a drag through the results (their list) or a tap in them.
                results
                    .simultaneousGesture(TapGesture().onEnded { focused = false })
            } else if recentSearches.isEmpty, openTags.isEmpty, tokens.isEmpty {
                // Nothing typed and nothing to offer yet: the hint in the middle of the page.
                EmptyStateView(
                    title: "",
                    message: "Type to search your entries, go to a place, smart filter or bowl, or ask Porridge. Tags show up here once you have some.",
                    systemImage: "magnifyingglass"
                )
                .scrollDismissesKeyboard(.interactively)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { focused = false })
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !recentSearches.isEmpty {
                            HStack {
                                Text("Recent Searches")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                                Spacer()
                                Button("Clear", action: onClearRecent)
                                    .font(.subheadline)
                                    .accessibilityLabel("Clear Recent Searches")
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(recentSearches, id: \.self) { line in
                                    Button { onRecent(line) } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                                            Text(line).foregroundStyle(.primary).lineLimit(1)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.vertical, 9)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("RecentSearch")
                                    if line != recentSearches.last { Divider() }
                                }
                            }
                        }
                        if openTags.isEmpty, tokens.isEmpty {
                            // Below the recent searches: a line of the page, not an empty page.
                            Text("Type to search your entries, go to a place, smart filter or bowl, or ask Porridge. Tags show up here once you have some.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else if !openTags.isEmpty {
                            Text("Tags")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.top, recentSearches.isEmpty ? 0 : 6)
                            FlowLayout(spacing: 8) {
                                ForEach(openTags, id: \.key) { tag in chip(tag) }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 6)
                }
                .scrollDismissesKeyboard(.interactively)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { focused = false })
            }
        }
    }

    /// Where the search looks: Everywhere, the Inbox or one bowl. "Ask Porridge" asks about the same.
    private var scopeChip: some View {
        Menu {
            Picker("Search In", selection: $scope) {
                Label("Everywhere", systemImage: "square.grid.2x2").tag(SearchAsk.Scope.everywhere)
                Label("Inbox", systemImage: "tray.fill").tag(SearchAsk.Scope.inbox)
                ForEach(bowls) { bowl in
                    Label(bowl.name, systemImage: "folder").tag(SearchAsk.Scope.bowl(Projects.key(bowl)))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            let isOn = scope != .everywhere
            HStack(spacing: 4) {
                Text(SearchAsk.searchName(scope, bowls: allBowls)).lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isOn ? Color.brandOnNavy : Color.brandNavy)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isOn ? Color.brandNavy : Color.brandSky.opacity(0.18), in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Search In")
        .accessibilityValue(SearchAsk.searchName(scope, bowls: allBowls))
    }

    /// The kinds as one menu chip ("All Kinds ⌄", or the chosen kind filled), for the largest text sizes.
    private var kindMenuChip: some View {
        Menu {
            Picker("Kind", selection: $kind.animation(.snappy)) {
                Text("All Kinds").tag(SearchKind?.none)
                ForEach(SearchKind.allCases, id: \.self) { option in Text(option.title).tag(Optional(option)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            let isOn = kind != nil
            HStack(spacing: 4) {
                Text(kind?.name ?? String(localized: "All Kinds")).lineLimit(2)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isOn ? Color.brandOnNavy : Color.brandNavy)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isOn ? Color.brandNavy : Color.brandSky.opacity(0.18), in: Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Kind")
        .accessibilityValue(kind?.name ?? String(localized: "All Kinds"))
    }

    private func kindChip(_ option: SearchKind) -> some View {
        let isOn = kind == option
        return Button {
            withAnimation(.snappy) { kind = isOn ? nil : option }
        } label: {
            Text(option.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isOn ? Color.brandOnNavy : Color.brandNavy)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isOn ? Color.brandNavy : Color.brandSky.opacity(0.18), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func chip(_ tag: (key: String, name: String, count: Int)) -> some View {
        Button {
            tokens.append(TagToken(name: tag.name))
            text = ""
        } label: {
            Text("#\(tag.name)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.brandNavy)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .chunkyPill(fill: .brandSky)
        }
        .buttonStyle(.plain)
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tokens) { token in
                        Button { tokens.removeAll { $0.id == token.id } } label: {
                            HStack(spacing: 4) {
                                Text("#\(token.name)")
                                Image(systemName: "xmark").font(.caption2.weight(.bold))
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.brandNavy)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.brandSky.opacity(0.4), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove #\(token.name)")
                    }
                    TextField("Search or Ask", text: $text)
                        .focused($focused)
                        .submitLabel(.search)
                        .onSubmit(onSubmit)
                        .autocorrectionDisabled()
                        .frame(minWidth: 90)
                        .accessibilityIdentifier("SearchField")
                }
            }
            if !text.isEmpty || !tokens.isEmpty {
                Button {
                    text = ""
                    tokens = []
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Text")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, typeSize.isAccessibilitySize ? 6 : 0)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .frame(minHeight: 44)
        .background(Color.appBackground, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.brandNavy.opacity(0.25), lineWidth: 1))
    }
}

/// A row of Search & Ask that is not an entry: "Ask Porridge: …" and the Go To rows.
struct SearchAskRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // With the largest text sizes the row is tall: the icon stays by the first line.
        HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: 12) {
            ThingsRowIcon(systemImage: systemImage, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Chips side by side, wrapping into lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
