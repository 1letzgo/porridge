import SwiftUI

/// Puts up "Bring Reminders into Porridge?" when the sync with Reminders asks for it (`ReminderSync.isAskingImport`):
/// once per device before the first import, and again from "Review" in Settings.
struct ReminderImportHost: ViewModifier {
    private let sync = ReminderSync.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { sync.isAskingImport && sync.preview != nil },
            set: { if !$0, sync.isAskingImport { sync.declineImport() } }
        )) {
            if let preview = sync.preview {
                ReminderImportSheet(preview: preview)
            }
        }
    }
}

/// The question before the first import: what it would bring, each list with its switch (on at first), Import and
/// Not Now. Lists switched off are left out on every device.
struct ReminderImportSheet: View {
    let preview: ReminderImportPreview
    @State private var selected: Set<String>
    private let sync = ReminderSync.shared

    init(preview: ReminderImportPreview) {
        self.preview = preview
        _selected = State(initialValue: Set(preview.entries.map(\.listID)))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(preview.summary(selected: selected))
                        .font(.body)
                } footer: {
                    Text("Afterwards new lists and reminders come in by themselves. You can change this for each list in Settings › General › Reminders.")
                }
                Section {
                    ForEach(preview.entries) { entry in
                        Toggle(isOn: Binding(
                            get: { selected.contains(entry.listID) },
                            set: { on in
                                if on { selected.insert(entry.listID) } else { selected.remove(entry.listID) }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).font(.body)
                                Text(ReminderImportPreview.detail(entry)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tint(Color.brandSky)
                    }
                } header: {
                    Text("Lists")
                } footer: {
                    if preview.entries.contains(where: { $0.kind == .inbox && !selected.contains($0.listID) }) {
                        Text("With the default list off, only reminders added there from now on come into the Inbox.")
                    }
                }
            }
            .navigationTitle("Bring Reminders into Porridge?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { sync.declineImport() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        sync.confirmImport(leavingOut: Set(preview.entries.map(\.listID)).subtracting(selected))
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}
