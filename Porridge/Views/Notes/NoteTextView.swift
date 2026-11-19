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
    /// As tall as its text, inside a page that scrolls as a whole; at least `minimumGrowingHeight`, so a tap below a short text still lands here.
    var growsWithText = false
    private let minimumGrowingHeight: CGFloat = 480

    func makeCoordinator() -> NoteTextCoordinator {
        NoteTextCoordinator(text: NoteTextBinding($text), controller: controller)
    }

    func makeUIView(context: Context) -> NotePlatformTextView {
        let textView = NotePlatformTextView(usingTextLayoutManager: true)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = NoteMarkdown.baseFont(kind: .paragraph)
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 200, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.keyboardDismissMode = .interactive
        textView.isScrollEnabled = !growsWithText
        textView.alwaysBounceVertical = !growsWithText
        textView.allowsEditingTextAttributes = false
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
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
        // Typing that is still on its way to the note is newer than a text from outside: it is written next
        // and wins, instead of being replaced here.
        if text != coordinator.lastWritten, !coordinator.hasPendingCommit { coordinator.load(text) }
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

