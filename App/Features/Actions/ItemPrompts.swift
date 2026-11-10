// The Rename box and the "Delete N items?" question, as popovers under the card: the panel never
// becomes the active app, and a popover is the one dialog that still takes typing there.
import ClipCore
import SwiftUI

/// A one-line box with the card's current name. Return or the button saves it; an empty name
/// puts the card's first line back.
struct RenamePrompt: View {
    let item: ClipboardItem
    let model: PanelModel

    @State private var name: String

    init(item: ClipboardItem, model: PanelModel) {
        self.item = item
        self.model = model
        _name = State(initialValue: item.title ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rename").font(.headline)
            HStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(save)
                    .accessibilityIdentifier("item-name")
                Button("Rename", action: save)
                    .keyboardShortcut(.defaultAction)
            }
            Text("Leave it empty to show the first line again.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func save() { model.rename(item, to: name) }
}

/// Asks before the selected cards go. Esc or Cancel keeps them; Return or Delete removes them.
struct DeletePrompt: View {
    let ids: [Int64]
    let model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Delete ^[\(ids.count) items](inflect: true)?").font(.headline)
            Text("This cannot be undone.").foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.prompt = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) { model.delete(ids: ids) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("delete-items")
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}
