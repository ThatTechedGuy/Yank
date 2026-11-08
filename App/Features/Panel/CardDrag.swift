// Dragging cards out of the panel into other apps: a text card into TextEdit, an image into
// Keynote, a file onto the Desktop. Every selected card goes, left to right, each as its own
// pasteboard item with every type that was saved, so the other app gets exactly what a paste
// would give it.
//
// The drag itself is AppKit's (`NSDraggingSession`), not SwiftUI's `.draggable`, for one
// reason: SwiftUI gives the other app the choice of copying or moving, and Finder chose to
// move the file. A drag out of a clipboard history must only ever copy, and only an AppKit
// drag source can say so (`sourceOperationMaskFor` below). SwiftUI still notices the drag:
// a `DragGesture` on the card reports the pointer moving, and this modifier turns that into
// an AppKit session once the card's data has been read from the database.
//
// `enum CardDragState` is the small state machine: nothing, reading the data after the first
// pointer move, ready with the pasteboard items, session running. The data is read in the
// background, so a big image never freezes the pointer; the session begins on the next
// pointer move after it arrives.
import AppKit
import ClipCore
import ClipSystem
import SwiftUI

/// Where a drag out of one card is.
enum CardDragState {
    case idle
    case loading
    case ready([NSPasteboardItem])
    case dragging
}

/// The AppKit side of one card's drag: holds the state, the invisible view the session starts
/// from, and answers AppKit's questions about the drag. Copy only, see the file comment.
final class CardDragSource: NSObject, NSDraggingSource {
    var state = CardDragState.idle
    weak var view: NSView?

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation
    {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        state = .idle
    }
}

/// Makes a card draggable. Dragging a selected card takes the whole selection; a card outside
/// the selection goes alone. A file card whose file is gone refuses to start.
struct CardDrag: ViewModifier {
    let model: PanelModel
    let item: ClipboardItem

    @State private var source = CardDragSource()

    func body(content: Content) -> some View {
        content
            .background(DragSourceView(source: source))
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in pointerMoved() }
                    .onEnded { _ in
                        // Released before the data arrived, or before the session began: back
                        // to nothing. A running session resets itself when it ends.
                        if case .dragging = source.state { return }
                        source.state = .idle
                    }
            )
    }

    private func pointerMoved() {
        switch source.state {
        case .idle:
            source.state = .loading
            let items = model.selection.contains(item.id) ? model.selectedItems : [item]
            Task {
                let pasteboardItems = await load(items)
                // Still wanted? The pointer may have been released while the database read ran.
                guard case .loading = source.state else { return }
                source.state = pasteboardItems.map { .ready($0) } ?? .idle
            }
        case .ready(let pasteboardItems):
            // The event SwiftUI is handling right now is the pointer move; AppKit starts the
            // session from it, in the invisible view behind the card.
            guard let event = NSApp.currentEvent, let view = source.view else { return }
            let image = Self.snapshot(of: view)
            let draggingItems = pasteboardItems.map { pasteboardItem in
                let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
                draggingItem.setDraggingFrame(view.bounds, contents: nil)
                return draggingItem
            }
            // The picture under the pointer is the card itself; the other items ride along
            // unseen, so several cards drag as one picture.
            draggingItems.first?.setDraggingFrame(view.bounds, contents: image)
            source.state = .dragging
            view.beginDraggingSession(with: draggingItems, event: event, source: source)
        case .loading, .dragging:
            break
        }
    }

    /// Reads every card's saved types and builds one pasteboard item per saved item, in card
    /// order. Nil when a file card's file is gone (the card is marked so it says why) or a
    /// read fails.
    private func load(_ items: [ClipboardItem]) async -> [NSPasteboardItem]? {
        var pasteboardItems: [NSPasteboardItem] = []
        for item in items {
            guard let data = try? await model.store.data(for: item.id) else { return nil }
            if data.contains(where: \.isMissingFile) {
                model.missingFileIds.insert(item.id)
                return nil
            }
            pasteboardItems += SystemClipboard.pasteboardItems(for: data)
        }
        return pasteboardItems
    }

    /// A picture of the card as it is drawn right now, for the pointer to carry. The card is
    /// SwiftUI content drawn by the window, so the window's content view is asked to draw
    /// the card's rectangle into a bitmap.
    private static func snapshot(of view: NSView) -> NSImage? {
        guard let host = view.window?.contentView else { return nil }
        let rect = view.convert(view.bounds, to: host)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        host.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        return image
    }
}

/// An empty AppKit view behind the card, there only so a drag session has a view to start
/// from. `hitTest` returns nil, so clicks go through it to the card as before.
private struct DragSourceView: NSViewRepresentable {
    let source: CardDragSource

    func makeNSView(context: Context) -> PassThroughView {
        let view = PassThroughView()
        source.view = view
        return view
    }

    func updateNSView(_ nsView: PassThroughView, context: Context) {}

    final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// Lets the card be dragged into other apps (see CardDrag).
    func cardDrag(model: PanelModel, item: ClipboardItem) -> some View {
        modifier(CardDrag(model: model, item: item))
    }
}
