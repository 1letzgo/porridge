import SwiftData
import SwiftUI

/// The bowl of a note as a violet pill: a tap on it changes the bowl, the cross takes the note out. Without a bowl,
/// "+ Bowl" puts it into one. An entry is in one bowl at most; one from before that is in several shows each.
struct ProjectPills: View {
    let assigned: [String]
    /// Puts the note into the bowl, in place of the one it is in.
    let onChoose: (NoteFolder) -> Void
    /// Takes the note out of the bowl.
    let onRemove: (NoteFolder) -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: \NoteFolder.name) private var projects: [NoteFolder]
    @State private var creating = false
    @State private var name = ""

    var body: some View {
        let shown = projects.filter { assigned.contains(Projects.key($0)) }
        HStack(spacing: 8) {
            ForEach(shown) { project in
                HStack(spacing: 6) {
                    Menu { choices } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill").font(.caption)
                            Text(project.name).font(.subheadline.weight(.semibold))
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Bowl \(project.name)")
                    .accessibilityHint("Change Bowl")
                    Button { onRemove(project) } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove from Bowl")
                }
                .foregroundStyle(Color.brandProject)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .chunkyPill(fill: .brandProject)
                .fixedSize()
            }
            if shown.isEmpty {
                Menu { choices } label: {
                    Label("Bowl", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.brandProject)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .chunkyPill(fill: .gray)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("Add to Bowl")
            }
        }
        .alert("New Bowl", isPresented: $creating) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                if let project = Projects.create(name, in: context) { onChoose(project) }
            }
        }
    }

    /// The active bowls to choose from, the note's ticked, and a new one.
    @ViewBuilder
    private var choices: some View {
        // Not into a bowl shared with me to view only.
        ForEach(projects.filter { (!$0.isArchived && !BowlSharing.shared.isReadOnly($0.id)) || assigned.contains(Projects.key($0)) }) { project in
            Button { if !assigned.contains(Projects.key(project)) { onChoose(project) } } label: {
                if assigned.contains(Projects.key(project)) {
                    Label(project.name, systemImage: "checkmark")
                } else {
                    Text(project.name)
                }
            }
        }
        if !projects.isEmpty { Divider() }
        Button { name = ""; creating = true } label: { Label("New Bowl…", systemImage: "folder.badge.plus") }
    }
}

/// "Bowl" in a context menu: every bowl, the note's ticked; a long press moves the element into another one (`Projects.toggle`:
/// in place of its bowl) or, on the ticked one, out of it. Missing when there are no bowls yet.
struct ProjectMenu: View {
    let assigned: [String]
    let onToggle: (NoteFolder) -> Void

    @Query(sort: \NoteFolder.name) private var projects: [NoteFolder]

    var body: some View {
        if !projects.isEmpty {
            Menu {
                // Not into a bowl shared with me to view only.
                ForEach(projects.filter { !BowlSharing.shared.isReadOnly($0.id) || assigned.contains(Projects.key($0)) }) { project in
                    let key = Projects.key(project)
                    Button { onToggle(project) } label: {
                        if assigned.contains(key) {
                            Label(project.name, systemImage: "checkmark")
                        } else {
                            Text(project.name)
                        }
                    }
                }
            } label: {
                Label("Bowl", systemImage: "folder")
            }
        }
    }
}
