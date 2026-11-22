import SwiftUI

struct RootView: View {
    @AppStorage(AppSettings.onboardingDoneKey) private var onboardingDone = false

    @State private var showStoreError = AppContainer.storeError != nil

    var body: some View {
        // The settings are a page of the list (NotesView).
        NotesView()
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
