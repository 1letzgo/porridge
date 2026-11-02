import SwiftUI

/// The user's own meeting templates: a name and what the summary should look at.
struct SummaryTemplatesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var templates = SummaryTemplate.custom
    @State private var editing: SummaryTemplate?

    var body: some View {
        NavigationStack {
            List {
                if templates.isEmpty {
                    Text("Your own templates tell the summary what to look at, for example “Note every price that is mentioned”.")
                        .foregroundStyle(.secondary)
                }
                ForEach(templates) { template in
                    Button {
                        editing = template
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name).foregroundStyle(.primary)
                            Text(template.focus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .onDelete { offsets in
                    templates.remove(atOffsets: offsets)
                    SummaryTemplate.custom = templates
                }
            }
            .navigationTitle("Custom Templates")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editing = SummaryTemplate(id: UUID().uuidString, name: "", focus: "", sections: nil)
                    } label: {
                        Label("Add Template", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editing) { template in
                TemplateEditor(template: template) { saved in
                    if let index = templates.firstIndex(where: { $0.id == saved.id }) {
                        templates[index] = saved
                    } else {
                        templates.append(saved)
                    }
                    SummaryTemplate.custom = templates
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }
}

private struct TemplateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var template: SummaryTemplate
    let onSave: (SummaryTemplate) -> Void

    private var canSave: Bool {
        !template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !template.focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $template.name)
                Section("What should the summary look at?") {
                    TextEditor(text: $template.focus)
                        .frame(minHeight: 120)
                }
            }
            .navigationTitle("Template")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(template)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 300)
        #endif
    }
}
