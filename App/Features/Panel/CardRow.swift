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
                        let isSelected = item.id == model.selectedId
                        ItemCard(
                            item: item, shortcutNumber: index < 9 ? index + 1 : nil,
                            isSelected: isSelected, width: cardWidth
                        )
                        // Double-click pastes the card (with ⇧ held: as plain text). It must
                        // come before the single click, or the single click wins and the
                        // double one never fires. SwiftUI's tap gives no modifier keys, so
                        // they are read from AppKit's current keyboard state.
                        .onTapGesture(count: 2) {
                            model.paste(item, plainText: NSEvent.modifierFlags.contains(.shift))
                        }
                        .onTapGesture { model.selectedId = item.id }
                        // The large preview, anchored to the selected card so it opens above
                        // it. Only the selected card gets the modifier with a live binding;
                        // the others get a constant false, so SwiftUI tracks one popover.
                        .popover(
                            isPresented: isSelected ? $model.showsLargePreview : .constant(false),
                            arrowEdge: .top
                        ) {
                            LargePreview(item: item, model: model)
                        }
                        // Tells the model "card N is on screen"; near the end, that loads more.
                        .onAppear { model.cardDidAppear(at: index) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
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
