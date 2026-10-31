import SwiftData
import SwiftUI

/// The projects of a note or task as violet pills, and a menu to add it to more (or a new one).
/// `inherited` are the projects a task is in through its note: shown dimmed, changed on the note.
struct ProjectPills: View {
    let assigned: [String]
    var inherited: [String] = []
    let onToggle: (NoteFolder) -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: \NoteFolder.name) private var projects: [NoteFolder]
    @State private var creating = false
    @State private var name = ""

    var body: some View {
        HStack(spacing: 8) {
            ForEach(projects.filter { assigned.contains(Projects.key($0)) }) { project in
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").font(.caption)
                    Text(project.name).font(.subheadline.weight(.semibold))
                    Button { onToggle(project) } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove from Project")
                }
                .foregroundStyle(Color.brandProject)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .chunkyPill(fill: .brandProject)
            }
            ForEach(projects.filter { inherited.contains(Projects.key($0)) && !assigned.contains(Projects.key($0)) }) { project in
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.caption)
                    Text(project.name).font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(Color.brandProject.opacity(0.6))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .overlay(Capsule().strokeBorder(Color.brandProject.opacity(0.3), lineWidth: 1))
                .accessibilityLabel("\(project.name), from the note")
            }
            Menu {
                ForEach(projects) { project in
                    Button { onToggle(project) } label: {
                        if assigned.contains(Projects.key(project)) {
                            Label(project.name, systemImage: "checkmark")
                        } else {
                            Text(project.name)
                        }
                    }
                }
                if !projects.isEmpty { Divider() }
                Button { name = ""; creating = true } label: { Label("New Project…", systemImage: "folder.badge.plus") }
            } label: {
                Label("Project", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brandProject)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .chunkyPill(fill: .white)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Add to Project")
        }
        .alert("New Project", isPresented: $creating) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                if let project = Projects.create(name, in: context) { onToggle(project) }
            }
        }
    }
}
