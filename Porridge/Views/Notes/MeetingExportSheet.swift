import SwiftUI

/// Exports a meeting: summary and transcript can be chosen on their own, as a text file or a formatted PDF.
struct MeetingExportSheet: View {
    let note: Note

    @Environment(\.dismiss) private var dismiss
    @State private var includeSummary: Bool
    @State private var includeTranscript: Bool
    @State private var format = MeetingExport.Format.pdf
    @State private var file: URL?
    @State private var failed = false

    init(note: Note) {
        self.note = note
        _includeSummary = State(initialValue: !(note.summary ?? "").isEmpty)
        _includeTranscript = State(initialValue: !note.segments.isEmpty)
    }

    private var hasSummary: Bool { !(note.summary ?? "").isEmpty }
    private var hasTranscript: Bool { !note.segments.isEmpty }
    private var choice: String { "\(includeSummary)\(includeTranscript)\(format.rawValue)" }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(spacing: 0) {
                    Toggle("Summary", isOn: $includeSummary).disabled(!hasSummary)
                        .padding(.vertical, 8)
                    Rectangle().fill(Look.hairline).frame(height: 0.5)
                    Toggle("Transcript", isOn: $includeTranscript).disabled(!hasTranscript)
                        .padding(.vertical, 8)
                }
                .tint(.brandSky)

                TabSwitcher(selection: $format, options: MeetingExport.Format.allCases.map { (value: $0, title: $0.title) })

                if failed {
                    Text("The file could not be written.").font(.footnote).foregroundStyle(Color.brandDangerText)
                } else if !hasSummary, !hasTranscript {
                    Text("This meeting has no summary or transcript yet.").font(.footnote).foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if let file {
                    ShareLink(item: file) {
                        Label("Export", systemImage: "arrow.up.doc").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ChunkyButtonStyle())
                } else {
                    Button {} label: {
                        Label("Export", systemImage: "arrow.up.doc").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ChunkyButtonStyle())
                    .disabled(true)
                }
            }
            .padding(20)
            .background(Color.appBackground)
            .brandNavigationTitle("Export")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 320)
        #endif
        .task(id: choice) { await prepare() }
    }

    /// The file is ready before the button is tapped: the share sheet needs it right away.
    private func prepare() async {
        file = nil
        failed = false
        let export = MeetingExport(note: note, includeSummary: includeSummary, includeTranscript: includeTranscript)
        guard !export.isEmpty else { return }
        let format = format
        let result = await Task.detached { try? export.write(format) }.value
        guard !Task.isCancelled else { return }
        file = result
        failed = result == nil
    }
}
