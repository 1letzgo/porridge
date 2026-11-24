import SwiftData
import SwiftUI

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
