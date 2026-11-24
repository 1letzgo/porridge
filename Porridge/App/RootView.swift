import SwiftUI

struct RootView: View {
    @AppStorage(AppSettings.onboardingDoneKey) private var onboardingDone = false

    @State private var showStoreError = AppContainer.storeError != nil
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        // The three places as tabs (iPhone) or a split view (iPad); Settings is a page of the Bowls place.
        NotesView()
            // The undo toast after deleting, moving or clearing something; above the tab bar.
            .overlay(alignment: .bottom) {
                UndoToastView()
                    .padding(.bottom, sizeClass == .compact ? 62 : 16)
            }
            // The progress of an export and what to do with the archive.
            .modifier(ExportSheetHost())
            // Sharing a bowl: the system's sheet for its people, and the questions before stopping or leaving.
            .modifier(BowlShareHost())
            .fullScreenCoverOrSheet(isPresented: .init(get: { !onboardingDone }, set: { onboardingDone = !$0 })) {
                OnboardingView { onboardingDone = true }
            }
            .alert("Your Notes Could Not Be Opened", isPresented: $showStoreError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Porridge started without them. They are still on this device, but nothing you write now is kept. Please update the app or get in touch.\n\n\(AppContainer.storeError ?? "")")
            }
            // What the sharing of bowls has to say (a share that could not be opened, saved or left).
            .alert(
                "Sharing",
                isPresented: Binding(get: { BowlSharing.shared.notice != nil }, set: { if !$0 { BowlSharing.shared.notice = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(BowlSharing.shared.notice ?? "")
            }
    }
}
