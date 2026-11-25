import SwiftData
import SwiftUI

/// Keeps the widgets in step with the notes while the list is on screen: their copy (`WidgetSnapshot`) is written a
/// moment after the notes change, and what was ticked in a widget or added by a shortcut is taken in.
struct WidgetSyncModifier: ViewModifier {
    let notes: [Note]

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ProcessingService.self) private var processing

    /// Changes with everything the widgets show; a number, as it is asked at every redraw of the list. Only the
    /// entries a widget can show count (in the inbox, open to-dos), and only what it shows of them: the title (or
    /// first line), the due day, the repeat rule, whether it may be ticked (view-only bowls).
    private var signature: Int {
        var hasher = Hasher()
        for note in notes where !note.isDeleted && (note.isInInbox || (note.isTodo && !note.isDone)) {
            hasher.combine(note.id)
            // Edits (an entry without a title shows its first line), and the title itself.
            hasher.combine(note.updatedAt)
            hasher.combine(note.title)
            hasher.combine(note.isInInbox)
            hasher.combine(note.todoStateRaw)
            hasher.combine(note.todoDueDay)
            if note.isTodo, !note.isInInbox { hasher.combine(BowlSharing.shared.isReadOnly(note)) }
        }
        return hasher.finalize()
    }

    func body(content: Content) -> some View {
        content
            .task(id: signature) {
                // Several changes in a row (typing) make one write.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                WidgetSync.publish(notes)
            }
            .onAppear {
                WidgetStore.observeWidgetActionsOnce()
                WidgetBridge.complete = { [context] completion in WidgetSync.apply(completion, in: context) }
                takeInWidgetActions()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { takeInWidgetActions() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .porridgeWidgetAction)) { _ in takeInWidgetActions() }
            .onReceive(NotificationCenter.default.publisher(for: .porridgeShareInboxChanged)) { _ in
                ShareImport.importInbox(context: context, processing: processing)
            }
    }

    private func takeInWidgetActions() {
        WidgetSync.applyPending(in: context)
    }
}

private extension WidgetStore {
    @MainActor private static var observing = false

    /// The Darwin notification of a widget's tick reaches the app while it runs; registered once.
    @MainActor static func observeWidgetActionsOnce() {
        guard !observing else { return }
        observing = true
        observeWidgetActions()
    }
}
