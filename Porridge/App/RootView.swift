import SwiftUI

struct RootView: View {
    @AppStorage(AppSettings.onboardingDoneKey) private var onboardingDone = false

    @State private var showStoreError = AppContainer.storeError != nil
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The selection bar is up (the Inbox's or a bowl's Select): the undo toast keeps above it.
    @State private var selectionBarShown = false
    /// Where the selection bar stands, for the toast on an iPad.
    @State private var selectionBarFrame: CGRect?

    var body: some View {
        // The three places as tabs (iPhone) or a split view (iPad); Settings is a page of the Bowls place.
        NotesView()
            // The undo toast after deleting, moving or clearing something; above the tab bar and its raised "+".
            .onPreferenceChange(SelectionBarShownKey.self) { selectionBarShown = $0 }
            .onPreferenceChange(SelectionBarFrameKey.self) { selectionBarFrame = $0 }
            .overlay(alignment: .bottom) {
                GeometryReader { proxy in
                    // iPad: while choosing several, over the selection bar in the list column (as wide as the bar
                    // at most), not across the list and the entry.
                    let column = sizeClass != .compact && selectionBarShown ? selectionBarFrame : nil
                    let root = proxy.frame(in: .global)
                    // A phone keeps 70 pt for the tab bar, and the selection bar in its place is lower than that.
                    UndoToastView()
                        .frame(maxWidth: column.map(\.width) ?? .infinity)
                        .offset(x: column.map { $0.midX - root.midX } ?? 0)
                        .padding(.bottom, sizeClass == .compact || selectionBarShown ? 70 : 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .animation(.snappy, value: selectionBarShown)
                }
            }
            // The progress of an export and what to do with the archive.
            .modifier(ExportSheetHost())
            // Sharing a bowl: the system's sheet for its people, and the questions before stopping or leaving.
            .modifier(BowlShareHost())
            // "Bring Reminders into Porridge?" before the first import from Reminders.
            .modifier(ReminderImportHost())
            .fullScreenCoverOrSheet(isPresented: .init(get: { !onboardingDone }, set: { onboardingDone = !$0 })) {
                OnboardingView {
                    // The onboarding showed the places already: no "What's New" card after it.
                    WhatsNew.dismiss()
                    onboardingDone = true
                }
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
