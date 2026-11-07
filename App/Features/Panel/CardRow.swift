// The sideways row of cards. It scrolls, it only builds the cards that are on screen, it keeps
// the selected card in view, and it tells the model when the user nears the end so more
// history can load. ≈ a horizontal FlatList with `onEndReached`, or a RecyclerView.
import ClipCore
import SwiftUI

struct CardRow: View {
    let model: PanelModel

    var body: some View {
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
                        ItemCard(
                            item: item, shortcutNumber: index < 9 ? index + 1 : nil,
                            isSelected: item.id == model.selectedId
                        )
                        .onTapGesture { model.selectedId = item.id }
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
        .accessibilityIdentifier("cards")
    }
}
