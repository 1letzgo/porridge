import SwiftUI

/// Edits a summary with the same editor as the notes.
struct SummaryEditorSheet: View {
    @Binding var text: String

    @Environment(\.dismiss) private var dismiss
    @State private var editor = NoteEditorController()

    var body: some View {
        NavigationStack {
            NoteBodyEditor(text: $text, controller: editor)
                .padding()
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .background(Color.appGroupedBackground)
                .brandNavigationTitle("Summary")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            editor.blur()
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }
}
