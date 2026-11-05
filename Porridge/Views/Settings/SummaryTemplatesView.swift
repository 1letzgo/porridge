import SwiftUI

/// The user's own meeting templates: a name and what the summary should look at.
struct SummaryTemplatesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var templates = SummaryTemplate.custom
    @State private var editing: SummaryTemplate?
    @State private var deleting: SummaryTemplate?

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
                    deleting = offsets.first.map { templates[$0] }
                }
            }
            .alert(
                "Delete \(deleting?.name ?? "Template")?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    templates.removeAll { $0.id == deleting?.id }
                    SummaryTemplate.custom = templates
                }
            } message: {
                Text("This cannot be undone.")
            }
            .navigationTitle("Custom Templates")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
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
