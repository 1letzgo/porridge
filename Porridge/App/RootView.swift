import SwiftUI

struct RootView: View {
    @AppStorage(AppSettings.onboardingDoneKey) private var onboardingDone = false
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    @State private var showStoreError = AppContainer.storeError != nil

    var body: some View {
        // iOS pushes the settings onto the list (NotesView); the Mac has a Settings window (⌘,).
        NotesView(openSettings: {
            #if os(macOS)
            openSettings()
            #endif
        })
            .fullScreenCoverOrSheet(isPresented: .init(get: { !onboardingDone }, set: { onboardingDone = !$0 })) {
                OnboardingView { onboardingDone = true }
                    #if os(macOS)
                    .frame(minWidth: 520, minHeight: 640)
                    #endif
            }
            .alert("Your Notes Could Not Be Opened", isPresented: $showStoreError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Porridge started without them. They are still on this device, but nothing you write now is kept. Please update the app or get in touch.\n\n\(AppContainer.storeError ?? "")")
            }
    }
}
