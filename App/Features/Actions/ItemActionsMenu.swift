// A card's actions menu, in its two places: the right-click menu and the ⌘K popover. Both are built
// from the one `ItemAction` list, so a row added there shows up in both.
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

/// The ⌘K version: the same rows in a list the arrow keys move through. The list takes the keyboard
/// when it opens, so ⌘K ↓ ↓ Return needs no mouse. Share… and Open With show their own control and
/// want a click (Return on Open With uses the default app).
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

/// One row, by action. Delete is red.
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
                    Button(FileManager.default.displayName(atPath: app.path)) { model.open(item, with: app) }
                }
            }
            .disabled(apps.isEmpty)
        case .delete:
            Button(action.title, role: .destructive) { model.perform(action, on: item) }
        default:
            Button(action.title) { model.perform(action, on: item) }
        }
    }
}
