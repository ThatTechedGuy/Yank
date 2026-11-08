// What the editor window shows: a rich text box (bold, italics and underline with the usual
// ⌘B ⌘I ⌘U, which the Format menu's commands in YankApp provide) or the picture with its
// three tools, and along the bottom Cancel, Replace Original and Save as New. Replace asks
// first, because it throws the old bytes away. ≈ a modal edit form; the window around it is
// EditorWindow.
import ClipCore
import SwiftUI

struct EditorView: View {
    /// `@Bindable` lets the text box write into the `@Observable` editor (`$editor.text`).
    @Bindable var editor: ItemEditor
    /// Closes the window. Passed in, like the panel's `dismiss`, so this view knows no AppKit.
    let close: () -> Void

    @State private var confirmsReplace = false
    @FocusState private var textHasFocus: Bool

    var body: some View {
        VStack(spacing: 12) {
            if editor.editsImage {
                picture
            } else {
                // SwiftUI's rich text editor: an `AttributedString` binding keeps the runs of
                // formatting, where a `String` binding would keep only the characters.
                TextEditor(text: $editor.text)
                    .font(.body)
                    .focused($textHasFocus)
                    .accessibilityIdentifier("editor-text")
            }
            HStack {
                if editor.editsImage {
                    Button("Rotate Left") { editor.rotate(clockwise: false) }
                        .accessibilityIdentifier("rotate-left")
                    Button("Rotate Right") { editor.rotate(clockwise: true) }
                        .accessibilityIdentifier("rotate-right")
                    Button("Remove Background") { Task { await editor.removeBackground() } }
                        .accessibilityIdentifier("remove-background")
                } else {
                    Text("⌘B bold · ⌘I italic · ⌘U underline")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if editor.isBusy { ProgressView().controlSize(.small) }
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancel")
                if editor.original != nil {
                    Button("Replace Original") { confirmsReplace = true }
                        .accessibilityIdentifier("replace")
                }
                // ⌘S, not Return: Return in the text box is a new line.
                Button("Save as New") { save(replacing: false) }
                    .keyboardShortcut("s")
                    .accessibilityIdentifier("save-new")
            }
            .disabled(editor.isBusy)
            if let error = editor.error {
                Text(error)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("editor-error")
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 320)
        .confirmationDialog("Replace the original?", isPresented: $confirmsReplace) {
            Button("Replace", role: .destructive) { save(replacing: true) }
                .accessibilityIdentifier("confirm-replace")
        } message: {
            Text("The card keeps its place, name and pinboard; its old content is gone for good.")
        }
        // Read the item when the window opens, and put the cursor in the text box.
        .task {
            await editor.load()
            textHasFocus = true
        }
    }

    /// The picture, scaled to fit, over a faint checkerboard-like tint so a cut-out's
    /// transparent parts can be told from white.
    private var picture: some View {
        Group {
            if let data = editor.image, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary)
        .accessibilityIdentifier("editor-image")
    }

    private func save(replacing: Bool) {
        Task {
            if await editor.save(replacing: replacing) { close() }
        }
    }
}
