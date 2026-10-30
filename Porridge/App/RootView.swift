import SwiftUI

struct RootView: View {
    @AppStorage(AppSettings.onboardingDoneKey) private var onboardingDone = false
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

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
    }
}
