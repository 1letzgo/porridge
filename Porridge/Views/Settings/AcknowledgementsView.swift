import SwiftUI

/// The third-party packages and models the app uses, from `Acknowledgements.json` (built by
/// scripts/acknowledgements.py): name, version, license and the full license text.
struct Acknowledgements: Decodable {
    struct Entry: Decodable, Identifiable {
        let name: String
        let version: String
        let license: String
        let url: String
        /// Key into `licenses`: the same text is stored once.
        let text: String

        var id: String { name }
    }

    struct Section: Decodable, Identifiable {
        let title: String
        let entries: [Entry]

        var id: String { title }
    }

    let licenses: [String: String]
    let sections: [Section]

    static let bundled: Acknowledgements = {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode(Acknowledgements.self, from: data)
        else { return Acknowledgements(licenses: [:], sections: []) }
        return list
    }()
}

/// The Settings row that opens the list: pushed on iOS, a sheet in the Settings window of the Mac.
struct AcknowledgementsRow: View {
    #if os(macOS)
    @State private var isShown = false
    #endif

    var body: some View {
        #if os(iOS)
        NavigationLink {
            AcknowledgementsView()
        } label: {
            label
        }
        .buttonStyle(.plain)
        #else
        Button { isShown = true } label: { label }
            .buttonStyle(.plain)
            .sheet(isPresented: $isShown) {
                AcknowledgementsView()
                    .frame(width: 600, height: 680)
            }
        #endif
    }

    private var label: some View {
        HStack {
            Text("Acknowledgements").font(.body)
            Spacer(minLength: 12)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss
    private let list = Acknowledgements.bundled
    /// Entries whose license text is open.
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            ChromeBar(title: "Acknowledgements", systemImage: "heart.text.square.fill", onBack: { dismiss() })
                .padding(.bottom, Look.headerGap)
            #else
            HStack {
                Text("Acknowledgements").font(.title2.weight(.bold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            #endif
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    Text("Porridge is built with these open source packages and models. Thank you to everyone who made them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(list.sections) { section in
                        sectionView(section)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 32)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color.appBackground)
        .brandNavigationTitle("Acknowledgements")
        #if os(iOS)
        // Our own bar (ChromeBar) replaces the system one, as in Settings.
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    /// A group in the look of the Settings cards: bold title over a hairline, rows separated by hairlines.
    private func sectionView(_ section: Acknowledgements.Section) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(section.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                Rectangle().fill(Look.hairline).frame(height: 0.5)
            }
            .accessibilityAddTraits(.isHeader)

            ForEach(Array(section.entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 {
                    Rectangle().fill(Look.hairline).frame(height: 0.5)
                }
                entryView(entry)
            }
        }
    }

    private func entryView(_ entry: Acknowledgements.Entry) -> some View {
        let isOpen = expanded.contains(entry.id)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    if isOpen { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.body)
                        Text([entry.version, entry.license].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Hides the license" : "Shows the license")

            if isOpen {
                if let url = URL(string: entry.url) {
                    Link(entry.url, destination: url)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(list.licenses[entry.text] ?? "")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .flatPanel(.secondary, padding: 12)
            }
        }
    }
}
