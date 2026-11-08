// The sideways row of cards. It scrolls, it only builds the cards that are on screen, it keeps
// the selected card in view, it sizes the cards from its own height, it shows the large
// preview above the selected card, and it tells the model when the user nears the end so more
// history can load. ≈ a horizontal FlatList with `onEndReached`, or a RecyclerView.
import ClipCore
import SwiftUI

struct CardRow: View {
    let model: PanelModel

    /// The row's height, measured as it is laid out; the cards' width follows it.
    @State private var height: CGFloat = 0

    var body: some View {
        @Bindable var model = model
        // Paste's cards are a little taller than wide; the width follows the panel's height so
        // a taller panel gets bigger cards, not just taller ones. 12 is the bottom padding.
        let cardWidth = max(120, (height - 12) * 0.82)
        // `ScrollViewReader` hands us a `proxy` that can scroll the row to a given card id,
        // like `flatListRef.scrollToIndex`. Scrolling follows the selection one way only:
        // scrolling with the wheel or trackpad never changes what is selected.
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                // `LazyHStack` creates a card's view only when it is about to come on screen,
                // so a list of 100,000 items costs as much as the dozen that fit (≈ FlatList,
                // not ScrollView + map). `enumerated` gives each card its position for the
                // "load more" check; `id: \.element.id` keys cards by item id, like a React
                // `key`.
                LazyHStack(spacing: 10) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        let isLead = item.id == model.selectedId
                        ItemCard(
                            item: item, shortcutNumber: index < 9 ? index + 1 : nil,
                            isSelected: model.selection.contains(item.id), isLead: isLead,
                            fileIsMissing: model.missingFileIds.contains(item.id), width: cardWidth,
                            position: index + 1, listSize: model.listSizeDescription
                        )
                        // Double-click pastes the card (with ⇧ held: as plain text). It must
                        // come before the single click, or the single click wins and the
                        // double one never fires. SwiftUI's tap gives no modifier keys, so
                        // they are read from AppKit's current keyboard state. A single click
                        // selects the card alone; with ⌘ held it joins or leaves the selection.
                        .onTapGesture(count: 2) {
                            model.paste(item, plainText: NSEvent.modifierFlags.contains(.shift))
                        }
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.command) {
                                model.toggleSelection(of: item.id)
                            } else {
                                model.selectedId = item.id
                            }
                        }
                        .cardDrag(model: model, item: item)
                        // The large preview, anchored to the lead card so it opens above it.
                        // Only the lead card gets the modifier with a live binding; the others
                        // get a constant false, so SwiftUI tracks one popover.
                        .popover(
                            isPresented: isLead ? $model.showsLargePreview : .constant(false),
                            arrowEdge: .top
                        ) {
                            LargePreview(item: item, model: model)
                        }
                        // Right-click: the actions menu.
                        .contextMenu { ItemActionsMenu(item: item, model: model) }
                        // The ⌘K menu, the Rename box or the Delete question, whichever is
                        // open on this card. Same one-live-binding trick as the preview.
                        .popover(
                            isPresented: model.prompt?.anchorId == item.id
                                ? Binding(get: { true }, set: { if !$0 { model.prompt = nil } })
                                : .constant(false),
                            arrowEdge: .top
                        ) {
                            switch model.prompt {
                            case .actions: ActionsPopover(item: item, model: model)
                            case .rename: RenamePrompt(item: item, model: model)
                            case .delete(let ids, _): DeletePrompt(ids: ids, model: model)
                            case nil: EmptyView()
                            }
                        }
                        // A file card checks, as it comes on screen, that its file is still
                        // there. `.task` runs when the card appears and is cancelled when it
                        // leaves, like a `useEffect` with cleanup.
                        .task { if item.kind == .file { await model.checkFile(of: item) } }
                        // The ⌘P chooser, when there are several pinboards to pick from: the
                        // same rows as the menu, above the card. Same one-live-binding trick
                        // as the preview.
                        .popover(
                            isPresented: model.pinChooserItemId == item.id
                                ? Binding(
                                    get: { true }, set: { if !$0 { model.pinChooserItemId = nil } })
                                : .constant(false),
                            arrowEdge: .top
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                PinChoices(item: item, model: model)
                                    .buttonStyle(.borderless)
                            }
                            .padding(12)
                        }
                        // Tells the model "card N is on screen"; near the end, that loads more.
                        .onAppear { model.cardDidAppear(at: index) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                // One named group holding the cards, so VoiceOver announces "Cards" on the
                // way in; `.contain` keeps each card its own element inside it.
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Cards")
            }
            // No scroll bar: the row is browsed with the keys, the wheel or the trackpad, and
            // the bar would sit on top of the cards.
            .scrollIndicators(.hidden)
            // When the selection changes (← →, a new copy arriving), scroll just enough to show
            // the selected card. `anchor: nil` means "the smallest move that makes it fully
            // visible", so a card already on screen does not shift. `initial: true` also runs
            // it once at first draw.
            .onChange(of: model.selectedId, initial: true) { _, id in
                if let id { proxy.scrollTo(id, anchor: nil) }
            }
        }
        // Measures the row. `onGeometryChange` runs when the size changes, nowhere else.
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
        .accessibilityIdentifier("cards")
    }
}
