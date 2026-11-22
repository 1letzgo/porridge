import SwiftData
import SwiftUI
import UIKit

/// Exporting on iOS: everything (Settings) or one bowl (its menu) is written as a .zip in the app's temporary
/// folder while a sheet shows the progress; then it is saved to Files or shared. Every place that offers it uses one
/// call; the sheet is SwiftUI's own, on the root view (`ExportSheetHost`). Presented by UIKit over the root view
/// controller instead, the Import menu of the home bar came back without its label for a moment afterwards.
@MainActor
@Observable
final class ExportPresenter {
    static let shared = ExportPresenter()

    /// The export the sheet shows, while it is up.
    private(set) var run: ExportRun?
    @ObservationIgnored private var directory: URL?

    func export(_ scope: FullExport.Scope, title: String, context: ModelContext) {
        guard run == nil else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Exports/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let run = ExportRun(scope: scope, title: title)
        self.run = run
        self.directory = directory
        run.start(context: context, into: directory, zip: true)
    }

    /// The sheet closed: a running export stops, the temporary copy goes (what was saved is a copy of it).
    func close() {
        run?.cancel()
        run = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    func save(_ url: URL) {
        guard let presenter = Self.topViewController() else { return }
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        presenter.present(picker, animated: true)
    }

    func share(_ url: URL) {
        guard let presenter = Self.topViewController() else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

extension ExportRun: Identifiable {}

/// Shows the sheet of `ExportPresenter` (on the root view).
struct ExportSheetHost: ViewModifier {
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { ExportPresenter.shared.run }, set: { if $0 == nil { ExportPresenter.shared.close() } })) { run in
            ExportSheet(run: run) { ExportPresenter.shared.close() }
                .presentationDetents([.medium])
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled()
        }
    }
}

/// The progress of an export, cancelable; once it is done, where to put the archive.
struct ExportSheet: View {
    let run: ExportRun
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text(run.title)
                .font(.headline)
                .lineLimit(1)
            switch run.state {
            case .running, .packing:
                ProgressView(value: run.state == .packing ? 1 : run.fraction)
                    .tint(Color.brandSky)
                Text(run.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Cancel", role: .cancel) { onClose() }
                    .buttonStyle(PillButtonStyle())
            case .finished(let url):
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Color.brandSky)
                    .accessibilityHidden(true)
                Text(run.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(url.lastPathComponent)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button("Save to Files…") { ExportPresenter.shared.save(url) }
                        .buttonStyle(PillButtonStyle())
                    Button("Share…") { ExportPresenter.shared.share(url) }
                        .buttonStyle(PillButtonStyle())
                }
                Button("Done") { onClose() }
                    .fontWeight(.semibold)
            case .failed, .cancelled:
                Text(run.statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Close") { onClose() }
                    .fontWeight(.semibold)
            }
        }
        .padding(24)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
    }
}

/// Settings › General: everything as files, to keep or to take elsewhere.
struct ExportCard: View {
    @Environment(\.modelContext) private var context

    var body: some View {
        SettingsCard(title: "Export") {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Export Everything").font(.body)
                    Text("A Markdown file for each entry with its attachments and recordings, and all data as JSON, in one .zip.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Export…") {
                    ExportPresenter.shared.export(.everything, title: String(localized: "Export Everything"), context: context)
                }
                .buttonStyle(PillButtonStyle())
            }
        }
    }
}

/// The entry of a bowl's menu that exports it.
struct ExportBowlButton: View {
    let project: NoteFolder
    @Environment(\.modelContext) private var context

    var body: some View {
        Button {
            ExportPresenter.shared.export(.bowl(project.id), title: String(localized: "Export “\(project.name)”"), context: context)
        } label: {
            Label("Export Bowl…", systemImage: "square.and.arrow.up")
        }
    }
}
