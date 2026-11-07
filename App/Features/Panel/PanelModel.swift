// The panel's state: the cards it shows, which one is selected, what is typed in search, and
// whether it is on screen. The views read it and re-render when it changes; the window shell
// and the keyboard handlers change it. ≈ a Zustand store for one screen, or an Android
// ViewModel. `@Observable` makes SwiftUI track every stored property, so a view that reads
// `model.items` re-renders when the list changes and nothing else does.
//
// It is the only thing that talks to the Store for the panel, and it keeps the list alive
// with a live query: the Store delivers the newest items now and again after every change,
// so a copy made while the panel is open appears on its own.
import ClipCore
import SwiftUI

@Observable final class PanelModel {
    /// How many items the live list asks for at first, and how many more each time the user
    /// nears the end. 200 cards is far more than fit on any screen, so the first page always
    /// covers what is visible and a few screens of scrolling.
    static let pageSize = 200

    /// The cards, newest first. Only the first `limit` items of the history.
    private(set) var items: [ClipboardItem] = []
    /// The id of the selected card, if any. An id, not an index, so the selection survives a new
    /// copy arriving at the front of the list.
    var selectedId: Int64?
    /// What is typed in the search box. Not used yet: searching comes later.
    var searchText = ""
    /// Whether the panel is on screen. The view uses it to put the cursor in search on open.
    private(set) var isVisible = false

    private let store: Store
    /// The task running the live query. Cancelling it stops the query; a new one starts when
    /// the limit changes.
    private var liveList: Task<Void, Never>?
    /// How many items the live query asks for. Grows as the user scrolls towards the end.
    private var limit = pageSize

    init(store: Store) {
        self.store = store
        startLiveList()
    }

    /// Starts (or restarts, with the current limit) the live query that keeps `items` fresh.
    /// It runs all the time, not only while the panel is open, so the cards are already loaded
    /// when the panel appears and opening it costs no database read.
    private func startLiveList() {
        liveList?.cancel()
        // `for try await` loops over each delivery as it arrives, like `for await` over an
        // async iterator in JS. The body runs on the main thread, because this class does.
        liveList = Task { [store, limit] in
            do {
                for try await items in store.observeItems(limit: limit) {
                    self.items = items
                    // The selected card may have been deleted; fall back to the first one.
                    if let selectedId, !items.contains(where: { $0.id == selectedId }) {
                        self.selectedId = items.first?.id
                    }
                }
            } catch {
                Log.ui.error("the panel's live list stopped: \(error, privacy: .public)")
            }
        }
    }

    /// The row calls this as each card comes on screen. Near the end of what is loaded, the
    /// live query is restarted asking for one more page, so the row never runs out while
    /// there is more history. Only when the list is full: a short history never grows.
    // shortcut: the live query re-reads every loaded item on each change, so with the whole
    // history loaded a copy made while the panel is open re-reads it all; fine up to the
    // measured sizes, switch to paging below a fixed observed window if that ever stalls.
    func cardDidAppear(at index: Int) {
        guard items.count == limit, index >= items.count - Self.pageSize / 2 else { return }
        limit += Self.pageSize
        startLiveList()
    }

    /// Selects the card after the selected one (→). Stays put at the end.
    func selectNext() { moveSelection(by: 1) }

    /// Selects the card before the selected one (←). Stays put at the start.
    func selectPrevious() { moveSelection(by: -1) }

    private func moveSelection(by step: Int) {
        guard let index = items.firstIndex(where: { $0.id == selectedId }) else {
            selectedId = items.first?.id
            return
        }
        let target = index + step
        guard items.indices.contains(target) else { return }
        selectedId = items[target].id
    }

    /// Called by the window when the panel comes on screen: the newest card is selected and
    /// search starts empty, the way Paste opens.
    func didShow() {
        selectedId = items.first?.id
        searchText = ""
        isVisible = true
    }

    /// Called by the window when the panel leaves the screen. A list that grew while scrolling
    /// shrinks back to one page, so the live query does little work while the panel is hidden.
    func didHide() {
        isVisible = false
        if limit != Self.pageSize {
            limit = Self.pageSize
            startLiveList()
        }
    }
}
