import SwiftUI

/// What a meeting is summarized with: the model, for this one summary, and the template. Tapping a template starts.
struct SummaryOptionsSheet: View {
    let replacesSummary: Bool
    let onStart: (SummaryTemplate, SummaryModel) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = SummaryModel.current

    /// The default is always there, also when it still has to download.
    private var options: [(value: SummaryModel, title: String)] {
        var models = SummaryModel.available
        if !models.contains(SummaryModel.current) { models.insert(SummaryModel.current, at: 0) }
        return models.map { (value: $0, title: $0.menuTitle) }
    }

    private var hint: String? {
        switch model {
        case .cloud(let provider, _): "The transcript goes to \(provider == .custom ? "your server" : provider.label)."
        case .local(let local): model.isOnHand ? nil : "The model downloads first (\(local.sizeText))."
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    MenuRow(title: "Model", selection: $model, options: options)
                    if let hint {
                        Text(hint).font(.footnote).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Template")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color.brandSkyText)
                            .padding(.top, 8)
                            .padding(.bottom, 6)
                        Rectangle().fill(Look.hairline).frame(height: 0.5)
                        ForEach(SummaryTemplate.all) { template in
                            Button {
                                dismiss()
                                onStart(template, model)
                            } label: {
                                Text(template.name)
                                    .font(.body)
                                    .foregroundStyle(Color.brandNavy)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 12)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Rectangle().fill(Look.hairline).frame(height: 0.5)
                        }
                    }
                    if replacesSummary {
                        Text("This replaces the current summary; your edits to it are lost.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .background(Color.appBackground)
            .brandNavigationTitle(replacesSummary ? "Summarize Again" : "Summarize")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }
}
