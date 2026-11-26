import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The body of a note: one text view with headings, lists, checklists and bold/italic, stored as Markdown
/// (see `NoteMarkdown`). The format bar sits above the keyboard.
struct NoteBodyEditor: View {
    @Binding var text: String
    var isEditable = true
    let controller: NoteEditorController
    /// Shown in the empty editor, under the format bar.
    var placeholder: String?
    /// iOS: as tall as its text, for a page that scrolls as a whole; that page then shows `NoteKeyboardBar` itself.
    var growsWithText = false
    /// The least height while it grows with its text (`NoteTextView.minimumGrowingHeight`).
    var minimumGrowingHeight: CGFloat = 480

    var body: some View {
        VStack(spacing: 0) {
            // The text view shows the placeholder itself: an overlay here read `controller.isEmpty`, which the
            // editor sets while SwiftUI is updating (loading a note), and could stay over the text.
            NoteTextView(text: $text, isEditable: isEditable, controller: controller, placeholder: placeholder, growsWithText: growsWithText, minimumGrowingHeight: minimumGrowingHeight)
        }
        .modifier(NoteEditorPresentations(controller: controller))
        .overlay(alignment: .bottom) {
            if controller.isEditing, isEditable, !growsWithText {
                // The note screen has 16 pt of padding all around; the bar reaches out to 12 pt from the edge, 6 pt above the keyboard.
                NoteKeyboardBar(controller: controller)
                    .padding(.horizontal, -4)
                    .padding(.bottom, -10)
            }
        }
    }

}

/// One glass bar over the keyboard with fixed places (design stage 7): Aa (format) · Checklist · ⊕ Insert (with Link
/// to Entry "[[") · ✦ Rewrite (the selection, `AIRewriteView`) · Outdent · Indent · Mic (dictation, where the page
/// offers it) · Done. Like a tab bar its symbols stop growing at the largest text sizes; a long press shows them big.
struct NoteKeyboardBar: View {
    let controller: NoteEditorController
    /// Starts dictating into the note (the note page); nil leaves the mic out.
    var dictate: (() -> Void)?

    var body: some View {
        let buttons = NoteFormatButtons(controller: controller)
        HStack(spacing: 0) {
            buttons.formatMenu.barSlot("Format", systemImage: "textformat")
            buttons.checklistButton.barSlot("Checklist", systemImage: "checklist")
            buttons.insertMenu.barSlot("Insert", systemImage: "plus.circle")
            Button {
                controller.rewriteOrAsk()
            } label: {
                Image(systemName: "sparkles")
            }
            .foregroundStyle(Color.brandProjectText)
            .accessibilityLabel("Rewrite with AI")
            .accessibilityIdentifier("EditorRewrite")
            .barSlot("Rewrite with AI", systemImage: "sparkles")
            buttons.outdentButton.barSlot("Outdent", systemImage: "decrease.indent")
            buttons.indentButton.barSlot("Indent", systemImage: "increase.indent")
            if let dictate {
                Button(action: dictate) { Image(systemName: "mic") }
                    .accessibilityLabel("Dictate")
                    .accessibilityIdentifier("EditorDictate")
                    .barSlot("Dictate", systemImage: "mic")
            }
            Button("Done") { controller.blur() }
                .fontWeight(.semibold)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 4)
                .accessibilityIdentifier("EditorDone")
        }
        .font(.title3)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .padding(.horizontal, 14)
        .frame(height: 52)
        .modifier(BarBackground())
        .transition(Motion.slide(.move(edge: .bottom).combined(with: .opacity)))
    }
}

private extension View {
    /// One place of the editor bar: the same width for each, and the large content viewer for a long press.
    func barSlot(_ title: LocalizedStringKey, systemImage: String) -> some View {
        frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityShowsLargeContentViewer { Label(title, systemImage: systemImage) }
    }
}

@MainActor
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
            Divider()
            Button { controller.perform(.moveLine(up: true)) } label: { Label("Move Line Up", systemImage: "arrow.up") }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button { controller.perform(.moveLine(up: false)) } label: { Label("Move Line Down", systemImage: "arrow.down") }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        } label: {
            Text("Aa").font(.title3.weight(.semibold))
        }
        .accessibilityLabel("Format")
    }

    /// Heading, checklist, table, image, divider, quote, code: one tap puts it at the cursor.
    var insertMenu: some View {
        Menu {
            let images = controller.canInsertImages
            ForEach(NoteInsertItem.allCases.filter { images || !$0.isImage }) { item in
                Button { controller.insert(item) } label: { Label(item.title, systemImage: item.systemImage) }
            }
            Divider()
            // "[[" at the cursor: the entries to link come up above the keyboard.
            Button { controller.beginEntryLink() } label: { Label("Link to Entry [[", systemImage: "link") }
            // A note template's text at the cursor.
            let templates = NoteTemplateStore.shared.templates
            if !templates.isEmpty {
                Divider()
                Menu {
                    ForEach(templates) { template in
                        Button { controller.insertTemplate(template) } label: { Label(template.name, systemImage: template.kind.symbol) }
                    }
                } label: {
                    Label("Insert Template", systemImage: "doc.on.doc")
                }
            }
        } label: {
            Image(systemName: "plus.circle")
        }
        .accessibilityLabel("Insert")
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

/// What the editor asks the screen to show: the table editor, the photo picker, the file importer. On the editor
/// itself, so they stay while the keyboard and its bar go away.
private struct NoteEditorPresentations: ViewModifier {
    let controller: NoteEditorController

    @State private var photo: PhotosPickerItem?

    func body(content: Content) -> some View {
        @Bindable var controller = controller
        content
            .sheet(item: $controller.tableRequest) { request in
                TableEditorView(table: request.table, isNew: request.isNew) { table, delete in
                    controller.finishTable(request, table: table, delete: delete)
                }
                .interactiveDismissDisabled()
            }
            .sheet(item: $controller.rewriteRequest) { request in
                AIRewriteView(request: request) { text, insertBelow in
                    controller.finishRewrite(request, text: text, insertBelow: insertBelow)
                } close: {
                    controller.rewriteRequest = nil
                }
            }
            .alert("Select Text to Rewrite", isPresented: $controller.rewriteNeedsSelection) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Select the words or lines to rewrite, then tap ✦ again.")
            }
            .photosPicker(isPresented: picking(.photos), selection: $photo, matching: .images, preferredItemEncoding: .compatible)
            .fileImporter(isPresented: picking(.files), allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                for url in urls { controller.insertImage(fileAt: url) }
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                Task { @MainActor in
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                    controller.insertImage(data: data, fileExtension: InlineImages.fileExtension(of: data), name: "Photo")
                }
            }
    }

    private func picking(_ source: ImagePickerSource) -> Binding<Bool> {
        Binding(get: { controller.imagePicker == source }, set: { if !$0, controller.imagePicker == source { controller.imagePicker = nil } })
    }
}
