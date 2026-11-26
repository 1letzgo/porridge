import SwiftUI
import UIKit

/// The one meta line under an entry's title (`EntryMeta`): the facts in grey, the "✦ File into …" suggestion of an
/// Inbox entry, then only the values that are set, each a coloured word with a small symbol that opens Details at its
/// section, and at the end "ⓘ Details". It wraps to two lines at most; values that do not fit become "+N".
struct EntryMetaLine: View {
    let facts: String
    let values: [EntryMeta.Value]
    /// The bowl of "✦ File into …" (an action, not a value).
    var suggestion: NoteFolder?
    /// Opens Details, at a section or at the top.
    let onOpen: (EntryDetails.Section.Kind?) -> Void
    var onFile: (NoteFolder) -> Void = { _ in }
    var onDropSuggestion: () -> Void = {}

    @State private var width: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    private static let spacing: CGFloat = 8
    private static let lineSpacing: CGFloat = 4

    var body: some View {
        let shown = visibleCount(in: width)
        let hidden = values.count - shown
        WrapLayout(spacing: Self.spacing, lineSpacing: Self.lineSpacing) {
            ForEach(Array(factParts.enumerated()), id: \.offset) { _, part in
                Text(part)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let suggestion {
                suggestionPill(suggestion)
            }
            ForEach(values.prefix(shown)) { value in
                Button { onOpen(value.section) } label: {
                    HStack(spacing: 3) {
                        // A tag's "#" is its symbol already ("#bills", not "# #bills").
                        if value.kind != .tag {
                            Image(systemName: Self.symbol(of: value))
                                .imageScale(.small)
                        }
                        Text(value.text).lineLimit(1)
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(Self.color(value.tone))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(value.text)
                .accessibilityHint("Opens Details")
            }
            if hidden > 0 {
                Button { onOpen(nil) } label: {
                    Text("+\(hidden)").fontWeight(.semibold).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(hidden) more")
                .accessibilityHint("Opens Details")
            }
            Button { onOpen(nil) } label: {
                Label("Details", systemImage: "info.circle")
                    .labelStyle(MetaLabelStyle())
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.brandSkyText)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("Details")
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private var factParts: [String] {
        let parts = facts.components(separatedBy: " · ")
        return parts.enumerated().map { $0.offset < parts.count - 1 ? $0.element + " ·" : $0.element }
    }

    private func suggestionPill(_ bowl: NoteFolder) -> some View {
        Button { onFile(bowl) } label: {
            HStack(spacing: 3) {
                Image(systemName: "sparkles").imageScale(.small)
                Text("File into \(bowl.name)").lineLimit(1)
            }
            .fontWeight(.semibold)
            .foregroundStyle(Color.brandProjectText)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(Color.brandProjectText.opacity(0.7), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { onFile(bowl) } label: { Label("File into \(bowl.name)", systemImage: "folder") }
            Button(role: .destructive) { onDropSuggestion() } label: { Label("Drop Suggestion", systemImage: "xmark") }
        }
        .accessibilityLabel("File into \(bowl.name)")
        .accessibilityHint("Suggested bowl")
    }

    // MARK: Fitting into two lines

    /// How many values fit, so that the facts, the suggestion, those values, "+N" (when any are left) and "Details"
    /// take two lines at most. Measured with the footnote font the views use; all of them before the first layout.
    private func visibleCount(in width: CGFloat) -> Int {
        guard width > 0, !values.isEmpty else { return values.count }
        let regular = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: UITraitCollection(preferredContentSizeCategory: typeSize.uiCategory))
        let bold = UIFont.systemFont(ofSize: regular.pointSize, weight: .semibold)
        func text(_ string: String, _ font: UIFont) -> CGFloat {
            ceil((string as NSString).size(withAttributes: [.font: font]).width) + 1
        }
        let symbol = ceil(bold.pointSize * 1.05) + 3
        let fixed = factParts.map { text($0, regular) }
            + (suggestion.map { [text(String(localized: "File into \($0.name)"), bold) + symbol + 18] } ?? [])
        let valueWidths = values.map { text($0.text, bold) + ($0.kind == .tag ? 0 : symbol) }
        let details = text(String(localized: "Details"), bold) + symbol
        for count in stride(from: values.count, through: 0, by: -1) {
            var items = fixed + valueWidths.prefix(count)
            if count < values.count { items.append(text("+\(values.count - count)", bold)) }
            items.append(details)
            if Self.lines(items, width: width) <= 2 { return count }
        }
        return 0
    }

    /// The lines a flow of items of these widths takes.
    static func lines(_ widths: [CGFloat], width: CGFloat) -> Int {
        var lines = 1
        var x: CGFloat = 0
        for item in widths {
            let item = min(item, width)
            if x > 0, x + spacing + item > width {
                lines += 1
                x = item
            } else {
                x += (x > 0 ? spacing : 0) + item
            }
        }
        return lines
    }

    // MARK: Look

    /// The bowl value's symbol: the "Bowl" asset is the app's coloured picture, so the line shows the folder the
    /// app uses for bowls everywhere else.
    static func symbol(of value: EntryMeta.Value) -> String {
        value.symbol == EntryMeta.bowlImage ? "folder.fill" : value.symbol
    }

    static func color(_ tone: EntryMeta.Value.Tone) -> Color {
        switch tone {
        case .bowl: .brandProjectText
        case .task: .brandTaskText
        case .danger: .brandDangerText
        case .navy: .brandNavy
        case .secondary: .secondary
        }
    }
}

/// Symbol and word close together, as in the rest of the meta line.
private struct MetaLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Views side by side, wrapping into lines; a view wider than the line gets the line's width (and truncates).
struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * lineSpacing
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for (index, size) in row.items {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [(Int, CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > width {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            let current = rows[rows.count - 1]
            if !current.items.isEmpty, current.width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.items.isEmpty }
    }
}

extension DynamicTypeSize {
    /// The UIKit size category of this size, to measure text as SwiftUI lays it out.
    var uiCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}
