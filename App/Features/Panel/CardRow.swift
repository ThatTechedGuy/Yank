// The sideways row of cards: lazy, sized from its own height, keeps the selected card in view,
// and tells the model when the user nears the end so more history can load.
import ClipCore
import SwiftUI

struct CardRow: View {
    let model: PanelModel

    /// The row's height, measured as it is laid out; the cards' width follows it.
    @State private var height: CGFloat = 0

    var body: some View {
        @Bindable var model = model
        // Square cards, as in Paste: the width is the row's height less its 4 top and 24 bottom
        // padding, so a taller panel gets bigger cards, not just taller ones.
        let cardWidth = max(120, height - 28)
        // Scrolling follows the selection one way only: the wheel or trackpad never changes
        // what is selected.
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 24) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        let isLead = item.id == model.selectedId
                        ItemCard(
                            item: item, shortcutNumber: index < 9 ? index + 1 : nil,
                            isSelected: model.selection.contains(item.id), isLead: isLead,
                            fileIsMissing: model.missingFileIds.contains(item.id), width: cardWidth,
                            position: index + 1, listSize: model.listSizeDescription,
                            categoryName: model.categories.first { $0.id == item.categoryId }?.name,
                            loadText: { await model.fullText(for: item) }
                        )
                        // The double-click must come before the single click, or the single
                        // click wins and it never fires. SwiftUI's tap gives no modifier keys,
                        // so they are read from AppKit's current keyboard state.
                        .onTapGesture(count: 2) {
                            model.paste([item], plainText: NSEvent.modifierFlags.contains(.shift))
                        }
                        .onTapGesture {
                            if NSEvent.modifierFlags.contains(.command) {
                                model.toggleSelection(of: item.id)
                            } else {
                                model.selectedId = item.id
                            }
                        }
                        .cardDrag(model: model, item: item)
                        // Only the lead card gets a live binding; the others get a constant
                        // false, so SwiftUI tracks one popover. The popovers below do the same.
                        .popover(
                            isPresented: isLead ? $model.showsLargePreview : .constant(false),
                            arrowEdge: .top
                        ) {
                            LargePreview(item: item, model: model)
                        }
                        .contextMenu { ItemActionsMenu(item: item, model: model) }
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
                            case .category:
                                ChoiceList(
                                    choices: model.categories.map(\.id), current: item.categoryId,
                                    title: { id in model.categories.first { $0.id == id }?.name ?? "" }
                                ) { model.setCategory($0, for: item) }
                            case .language:
                                ChoiceList(
                                    choices: Language.all, current: item.language, title: Language.displayName
                                ) {
                                    model.setLanguage($0, for: item)
                                }
                            case nil: EmptyView()
                            }
                        }
                        .task { if item.kind == .file { await model.checkFile(of: item) } }
                        // The ⌘P chooser, when there are several pinboards to pick from: the
                        // same rows as the menu.
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
                        // Near the end of the row, this makes the model load more.
                        .onAppear { model.cardDidAppear(at: index) }
                    }
                }
                // The 4 points on top leave room for the selected card's outline, which is
                // drawn outside the card.
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 24)
                // One named group, so VoiceOver announces "Cards" on the way in; each card
                // stays its own element inside it.
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Cards")
            }
            // No scroll bar: it would sit on top of the cards. `.never`, not `.hidden`: with a
            // mouse connected macOS shows full scroll bars, and `.hidden` lets it.
            .scrollIndicators(.never)
            // Keeps the selected card in view. `anchor: nil` is the smallest move that shows it
            // fully, so a card already on screen does not shift.
            .onChange(of: model.selectedId, initial: true) { _, id in
                if let id { proxy.scrollTo(id, anchor: nil) }
            }
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
        .accessibilityIdentifier("cards")
    }
}
