// What the editor window shows: a rich text box or the picture with its three tools, and along the
// bottom Cancel, Replace Original and Save as New. Replace asks first, because it throws the old
// bytes away.
import ClipCore
import SwiftUI

struct EditorView: View {
    @Bindable var editor: ItemEditor
    /// Closes the window. Passed in, so this view holds no reference to its NSWindow.
    let close: () -> Void

    @State private var confirmsReplace = false
    /// `editor.image` as pixels, nil until decoded.
    @State private var decodedPicture: NSImage?
    @FocusState private var textHasFocus: Bool

    var body: some View {
        VStack(spacing: 12) {
            if editor.editsImage {
                picture
            } else {
                // An `AttributedString` binding makes this the rich text editor; a `String` binding
                // would keep only the characters.
                TextEditor(text: $editor.text)
                    .font(.body)
                    .focused($textHasFocus)
                    .accessibilityIdentifier("editor-text")
            }
            HStack {
                if editor.editsImage {
                    Button("Rotate Left") { Task { await editor.rotate(clockwise: false) } }
                        .accessibilityIdentifier("rotate-left")
                    Button("Rotate Right") { Task { await editor.rotate(clockwise: true) } }
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
        .task {
            await editor.load()
            textHasFocus = true
        }
    }

    /// The picture, scaled to fit, over a faint tint so a cut-out's transparent parts can be
    /// told from white. Decoded off the main thread whenever the bytes change (a rotation, a
    /// removed background), so the window never freezes on a large photo.
    private var picture: some View {
        Group {
            if let decodedPicture {
                Image(nsImage: decodedPicture)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary)
        .accessibilityIdentifier("editor-image")
        .task(id: editor.image) {
            guard let data = editor.image else { return }
            decodedPicture = await ThumbnailCache.decode(data)
        }
    }

    private func save(replacing: Bool) {
        Task {
            if await editor.save(replacing: replacing) { close() }
        }
    }
}
