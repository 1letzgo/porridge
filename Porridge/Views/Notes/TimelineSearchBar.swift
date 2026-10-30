import SwiftUI

/// A tag as a chip in the search field.
struct TagToken: Identifiable, Hashable {
    let name: String
    var id: String { name.lowercased() }
}

/// The search view: a field, the tags as chips for quick filtering, and the matching notes below.
struct SearchPane<Results: View>: View {
    @Binding var text: String
    @Binding var tokens: [TagToken]
    let tags: [(key: String, name: String, count: Int)]
    let hasQuery: Bool
    @ViewBuilder var results: Results

    @FocusState private var focused: Bool

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
                results
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if openTags.isEmpty, tokens.isEmpty {
                            Text("Type a word to search your notes and meetings. Tags show up here once you have some.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else if !openTags.isEmpty {
                            Text("Tags")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
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
            }
        }
        .onAppear { focused = true }
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
                    TextField("Search", text: $text)
                        .focused($focused)
                        .submitLabel(.search)
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
                .accessibilityLabel("Clear text")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color.appBackground, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.brandNavy.opacity(0.25), lineWidth: 1))
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
