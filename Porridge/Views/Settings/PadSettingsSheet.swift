import SwiftUI

/// iPad of regular width: Settings as a sheet over the window (as the system's apps do), with the system's navigation
/// bar and Done; Known Voices and Acknowledgements are pushed inside it. On a phone Settings is a page of the stack.
struct PadSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path: [ListPage] = []

    var body: some View {
        NavigationStack(path: $path) {
            SettingsView(isEmbedded: true)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("SettingsDone")
                    }
                }
                .navigationDestination(for: ListPage.self) { page in
                    switch page {
                    case .voices: VoicesView()
                    case .acknowledgements: AcknowledgementsView()
                    default: EmptyView()
                    }
                }
        }
        .environment(\.openListPage) { path.append($0) }
        .environment(\.usesSystemBars, true)
        .emptyStateSheet()
    }
}
