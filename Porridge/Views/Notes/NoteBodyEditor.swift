import SwiftUI

/// Lets the note screen reach into the editor: cursor position, keyboard, formatting.
@MainActor
@Observable
final class NoteEditorController {
    @ObservationIgnored private weak var coordinator: NoteTextCoordinator?
    /// The body is being edited (the format bar is showing above the keyboard).
    var isEditing = false

    /// Cursor as a character offset in the note's Markdown; the end of the text when nothing is being edited.
    var cursorOffset: Int { coordinator?.cursorOffset() ?? 0 }

    func blur() { coordinator?.blur() }

    func perform(_ command: NoteEditorCommand) { coordinator?.perform(command) }

    func bind(_ coordinator: NoteTextCoordinator) { self.coordinator = coordinator }
}

/// The body of a note: one text view with headings, lists, checklists and bold/italic, stored as Markdown
/// (see `NoteMarkdown`). The format bar sits above the text on the Mac and above the keyboard on iOS.
struct NoteBodyEditor: View {
    @Binding var text: String
    var isEditable = true
    let controller: NoteEditorController
    /// Shown in the empty editor, under the format bar.
    var placeholder: String?
    /// iOS: as tall as its text, for a page that scrolls as a whole; that page then shows `NoteKeyboardBar` itself.
    var growsWithText = false

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            if isEditable { formatBar.padding(.bottom, 6) }
            #endif
            #if os(iOS)
            NoteTextView(text: $text, isEditable: isEditable, controller: controller, growsWithText: growsWithText)
                .overlay(alignment: .topLeading) { placeholderText }
            #else
            NoteTextView(text: $text, isEditable: isEditable, controller: controller)
                .overlay(alignment: .topLeading) { placeholderText }
            #endif
        }
        #if os(iOS)
        .overlay(alignment: .bottom) {
            if controller.isEditing, isEditable, !growsWithText {
                // The note screen has 16 pt of padding all around; the bar reaches out to 12 pt from the edge, 6 pt above the keyboard.
                NoteKeyboardBar(controller: controller)
                    .padding(.horizontal, -4)
                    .padding(.bottom, -10)
            }
        }
        #endif
    }

    @ViewBuilder private var placeholderText: some View {
        if let placeholder, text.isEmpty {
            Text(placeholder)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
                .allowsHitTesting(false)
        }
    }

    // MARK: Formatting

    private var formatBar: some View {
        let buttons = NoteFormatButtons(controller: controller)
        return HStack(spacing: 18) {
            buttons.formatMenu
            buttons.checklistButton
            buttons.outdentButton
            buttons.indentButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One bar over the keyboard with all the buttons, like in Notes.
struct NoteKeyboardBar: View {
    let controller: NoteEditorController

    var body: some View {
        let buttons = NoteFormatButtons(controller: controller)
        HStack {
            buttons.formatMenu
            Spacer()
            buttons.checklistButton
            Spacer()
            buttons.outdentButton
            Spacer()
            buttons.indentButton
            Spacer()
            Button("Done") { controller.blur() }.fontWeight(.semibold)
        }
        .font(.title3)
        .padding(.horizontal, 22)
        .frame(height: 52)
        .modifier(BarBackground())
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct NoteFormatButtons {
    let controller: NoteEditorController

    var formatMenu: some View {
        Menu {
            Button("Title") { controller.perform(.setKind(.heading(1))) }
            Button("Heading") { controller.perform(.setKind(.heading(2))) }
            Button("Subheading") { controller.perform(.setKind(.heading(3))) }
            Button("Body") { controller.perform(.setKind(.paragraph)) }
            Divider()
            Button { controller.perform(.toggleInline("**")) } label: { Label("Bold", systemImage: "bold") }
                .keyboardShortcut("b")
            Button { controller.perform(.toggleInline("*")) } label: { Label("Italic", systemImage: "italic") }
                .keyboardShortcut("i")
            Divider()
            Button { controller.perform(.setKind(.bullet)) } label: { Label("Bulleted List", systemImage: "list.bullet") }
            Button { controller.perform(.setKind(.numbered)) } label: { Label("Numbered List", systemImage: "list.number") }
            Button { controller.perform(.setKind(.quote)) } label: { Label("Quote", systemImage: "text.quote") }
        } label: {
            Image(systemName: "textformat")
        }
        .accessibilityLabel("Format")
    }

    var checklistButton: some View {
        Button { controller.perform(.setKind(.checklist(checked: false))) } label: { Image(systemName: "checklist") }
            .accessibilityLabel("Checklist")
    }

    var outdentButton: some View {
        Button { controller.perform(.shift(deeper: false)) } label: { Image(systemName: "decrease.indent") }
            .accessibilityLabel("Outdent")
    }

    var indentButton: some View {
        Button { controller.perform(.shift(deeper: true)) } label: { Image(systemName: "increase.indent") }
            .accessibilityLabel("Indent")
    }
}
