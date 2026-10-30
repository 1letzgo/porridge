import SwiftUI

/// Minimal block-level Markdown renderer for summaries (headings, bullets, checkboxes, paragraphs).
struct MarkdownText: View {
    let markdown: String
    /// Called with the line index when a checkbox is tapped; nil shows the checkboxes without a tap.
    var onToggleTask: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private enum Block {
        case heading(String)
        case bullet(String)
        case task(String, done: Bool, line: Int)
        case paragraph(String)
    }

    private var blocks: [Block] {
        markdown.components(separatedBy: "\n").enumerated().compactMap { index, rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("#") {
                return .heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
            }
            for (prefix, done) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true)] where line.hasPrefix(prefix) {
                return .task(String(line.dropFirst(prefix.count)), done: done, line: index)
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                return .bullet(String(line.dropFirst(2)))
            }
            return .paragraph(line)
        }
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let text):
            Text(inline(text))
                .font(.headline)
                .foregroundStyle(Color.accentColor)
                .padding(.top, 8)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Color.brandSky).fontWeight(.semibold)
                Text(inline(text))
            }
        case .task(let text, let done, let line):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let onToggleTask {
                    Button { onToggleTask(line) } label: {
                        Image(systemName: done ? "checkmark.square.fill" : "square")
                            .foregroundStyle(Color.brandSky)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(done ? "Done" : "Open")
                } else {
                    Image(systemName: done ? "checkmark.square.fill" : "square")
                        .foregroundStyle(Color.brandSky)
                }
                Text(inline(text))
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? .secondary : .primary)
            }
        case .paragraph(let text):
            Text(inline(text))
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
