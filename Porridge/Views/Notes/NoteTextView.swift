import SwiftUI
import UIKit

extension NoteTextBinding {
    init(_ binding: Binding<String>) {
        self.init(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0 })
    }
}

struct NoteTextView: UIViewRepresentable {
    @Binding var text: String
    var isEditable = true
    let controller: NoteEditorController
    /// Shown in the empty editor, by the text view itself (so it follows every change of the text at once).
    var placeholder: String?
    /// As tall as its text, inside a page that scrolls as a whole; at least `minimumGrowingHeight`, so a tap below a short text still lands here.
    var growsWithText = false
    /// A to-do's body is shorter: its "Add Subtask" follows right below instead of 480 pt down the page.
    var minimumGrowingHeight: CGFloat = 480
    /// Room under the last line, part of the view (a tap there lands in the text). A to-do's is small: its
    /// "Add Subtask" follows right under the text (with 200 pt it stood about 200 pt below "Notes and subtasks…").
    var bottomSpace: CGFloat = 200

    func makeCoordinator() -> NoteTextCoordinator {
        NoteTextCoordinator(text: NoteTextBinding($text), controller: controller)
    }

    func makeUIView(context: Context) -> NotePlatformTextView {
        let textView = NotePlatformTextView(usingTextLayoutManager: true)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = NoteMarkdown.baseFont(kind: .paragraph)
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: bottomSpace, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        textView.isScrollEnabled = !growsWithText
        textView.alwaysBounceVertical = !growsWithText
        textView.allowsEditingTextAttributes = false
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.placeholder = placeholder
        let tap = UITapGestureRecognizer(target: textView, action: #selector(NotePlatformTextView.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        textView.addGestureRecognizer(tap)

        context.coordinator.textView = textView
        context.coordinator.load(text)
        context.coordinator.controller.bind(context.coordinator)
        context.coordinator.observeAppEnd()
        textView.isEditable = isEditable
        return textView
    }

    func updateUIView(_ textView: NotePlatformTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = NoteTextBinding($text)
        textView.isEditable = isEditable
        if textView.placeholder != placeholder { textView.placeholder = placeholder }
        if textView.textContainerInset.bottom != bottomSpace {
            textView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: bottomSpace, right: 0)
        }
        guard text != coordinator.lastWritten else { return }
        if coordinator.hasPendingCommit {
            Self.mergeTicks(from: text, into: textView, coordinator: coordinator)
        } else {
            coordinator.load(text)
        }
    }

    /// Typing that is still on its way to the note is newer than a text from outside: it is written next and
    /// wins. Boxes ticked or unticked outside in the meantime (the to-do's box or row in the list, iPad split view)
    /// are kept though: they go into the editor, and the pending commit writes them back with the typing.
    /// Nothing else from outside is taken over. After the load `lastWritten` is the merged text, so the next
    /// update finds nothing more to merge (the outside ticks equal the base then).
    private static func mergeTicks(from outside: String, into textView: NotePlatformTextView, coordinator: NoteTextCoordinator) {
        // A word being composed (marked text) would be torn apart by a reload: typing wins as before.
        guard textView.markedTextRange == nil, let storage = textView.noteStorage else { return }
        let typed = NoteMarkdown.markdown(from: storage)
        let merged = Todos.mergeTicks(base: coordinator.lastWritten, winner: typed, loser: outside)
        guard merged != typed else { return }
        // Only the editor changes here; the note gets the merged text from the commit, not during this update.
        coordinator.load(merged)
        Task { @MainActor in
            if coordinator.hasPendingCommit { coordinator.flush() }
        }
    }

    static func dismantleUIView(_ textView: NotePlatformTextView, coordinator: NoteTextCoordinator) {
        if coordinator.hasPendingCommit { coordinator.flush() }
        coordinator.stopObserving()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NotePlatformTextView, context: Context) -> CGSize? {
        guard growsWithText, let width = proposal.width else { return nil }
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(fitted.height, minimumGrowingHeight))
    }
}

