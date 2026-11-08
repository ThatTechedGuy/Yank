// The rows of a card's actions menu, and the two places they appear: the right-click menu
// (SwiftUI's `.contextMenu` draws them as a real macOS menu, with the keyboard for free) and
// the ⌘K popover, a list above the card that ↑ ↓ walk and Return fires. Both are built from
// the one `ItemAction` list, so a row added there shows up in both. Most rows are plain
// buttons that hand the action to the model; three carry their own control: Pin to… is a
// submenu of the pinboards, Share… is SwiftUI's `ShareLink` (the system share sheet), Open
// With is a submenu of the apps that can open the card.
import ClipCore
import SwiftUI

/// The menu rows, for `.contextMenu`. Groups are separated the way Finder's menu is.
struct ItemActionsMenu: View {
    let item: ClipboardItem
    let model: PanelModel

    var body: some View {
        ForEach(ItemAction.available(for: item)) { action in
            if action.startsGroup { Divider() }
            ItemActionRow(action: action, item: item, model: model)
        }
    }
}

/// The ⌘K version: the same rows in a list the arrow keys move through. The list takes the
/// keyboard when it opens, so ⌘K ↓ ↓ Return needs no mouse. Return does the highlighted
/// action; Share… and Open With show their own control and want a click (Return on Open
/// With uses the default app).
struct ActionsPopover: View {
    let item: ClipboardItem
    let model: PanelModel

    @State private var highlighted: ItemAction? = .paste
    @FocusState private var isFocused: Bool

    var body: some View {
        let actions = ItemAction.available(for: item)
        List(actions, selection: $highlighted) { action in
            ItemActionRow(action: action, item: item, model: model)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("action-\(action.rawValue)")
                // The list tags each row with its `id` (a String) unless told otherwise, and a
                // tag that is not an `ItemAction` never matches `highlighted`, so ↑ ↓ would
                // move nothing and Return would always paste.
                .tag(action)
        }
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.return) {
            guard let highlighted else { return .ignored }
            model.perform(highlighted, on: item)
            return .handled
        }
        .scrollContentBackground(.hidden)
        // Tall enough for every row, so the list never scrolls.
        .frame(width: 240, height: CGFloat(actions.count) * 26 + 16)
        .accessibilityIdentifier("actions")
    }
}

/// One row, by action. Delete is red, Edit is greyed out until there is an editor.
private struct ItemActionRow: View {
    let action: ItemAction
    let item: ClipboardItem
    let model: PanelModel

    var body: some View {
        switch action {
        case .pinTo:
            if item.pinboardId != nil {
                Button("Unpin") { model.unpin(item.id) }
            } else {
                Menu(action.title) { PinChoices(item: item, model: model) }
            }
        case .share:
            ShareLink(
                item: ShareableItem(item: item, store: model.store),
                preview: SharePreview(item.title ?? item.cardText)
            ) {
                Text(action.title)
            }
        case .openWith:
            let apps = model.appsThatOpen(item)
            Menu(action.title) {
                ForEach(apps, id: \.self) { app in
                    // The app's name as Finder shows it, without ".app".
                    Button(FileManager.default.displayName(atPath: app.path)) { model.open(item, with: app) }
                }
            }
            .disabled(apps.isEmpty)
        case .edit:
            Button(action.title) {}.disabled(true)
        case .delete:
            Button(action.title, role: .destructive) { model.perform(action, on: item) }
        default:
            Button(action.title) { model.perform(action, on: item) }
        }
    }
}
