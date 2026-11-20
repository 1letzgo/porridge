import SwiftUI

/// Edits a summary with the same editor as the notes.
struct SummaryEditorSheet: View {
    @Binding var text: String
    /// Runs once the sheet is gone (Done or swiped away), after the editor has handed over its last typing.
    var onFinish: () -> Void = {}

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
        .onDisappear {
            // Swiped closed: what was typed in the last moment must reach the summary before it is cleaned up.
            editor.blur()
            onFinish()
        }
    }
}
