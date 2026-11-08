// The panel's state: the cards it shows, which one is selected, what is typed in search, and
// whether it is on screen. The views read it and re-render when it changes; the window shell
// and the keyboard handlers change it. ≈ a Zustand store for one screen, or an Android
// ViewModel. `@Observable` makes SwiftUI track every stored property, so a view that reads
// `model.items` re-renders when the list changes and nothing else does.
//
// It is the only thing that talks to the Store for the panel, and it keeps the list alive
// with a live query: the Store delivers the newest items now and again after every change,
// so a copy made while the panel is open appears on its own. Pasting goes through it too: the
// views say which card and whether ⇧ was held, and the model adds the user's settings and
// hands the job to PasteService.
//
// Typing in the search box swaps the live list for search results: each keystroke cancels the
// search still running for the previous text and starts a new one, so the cards always show
// the latest text and a slow search can never overwrite a newer one. Clearing the box shows
// the live list again, which kept running underneath.
import ClipCore
import SwiftUI

@Observable final class PanelModel {
    /// How many items the live list asks for at first, and how many more each time the user
    /// nears the end. 200 cards is far more than fit on any screen, so the first page always
    /// covers what is visible and a few screens of scrolling.
    static let pageSize = 200

    /// The cards on screen: the search results while something is typed, otherwise the live
    /// list. Computed, so a view reading it re-renders when either source changes.
    var items: [ClipboardItem] { searchResults ?? liveItems }
    /// The newest items, kept fresh by the live query. Only the first `limit` of the history.
    private(set) var liveItems: [ClipboardItem] = []
    /// The items matching `searchText`, or nil when the box is empty or holds too little to
    /// search (one letter, only spaces or punctuation): the full list shows then.
    // shortcut: results are a snapshot, a copy made while they show does not appear in them,
    // and they are capped at one page with no paging; revisit if either is ever noticed.
    private var searchResults: [ClipboardItem]?
    /// The id of the selected card, if any. An id, not an index, so the selection survives a new
    /// copy arriving at the front of the list.
    var selectedId: Int64?
    /// What is typed in the search box. Every change starts a search for the new text.
    /// (`didSet` runs after the value is stored, ≈ a setter hook; `oldValue` is the previous
    /// text. SwiftUI's binding sets it again on focus changes, so same-text sets are ignored.)
    var searchText = "" {
        didSet { if searchText != oldValue { startSearch() } }
    }
    /// Whether the panel is on screen. The view uses it to put the cursor in search on open.
    private(set) var isVisible = false
    /// True when Return would paste into the active app but macOS does not let Yank press ⌘V:
    /// the panel then shows a hint. Checked each time the panel opens, so granting the
    /// permission in System Settings is noticed on the next ⇧⌘V without a restart.
    private(set) var needsAccessibility = false

    private let store: Store
    private let pasteService: PasteService
    /// The task running the live query. Cancelling it stops the query; a new one starts when
    /// the limit changes.
    private var liveList: Task<Void, Never>?
    /// The search running for the current text, if any. Cancelled by the next keystroke.
    private var search: Task<Void, Never>?
    /// How many items the live query asks for. Grows as the user scrolls towards the end.
    private var limit = pageSize

    init(store: Store, pasteService: PasteService) {
        self.store = store
        self.pasteService = pasteService
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
                    self.liveItems = items
                    // The selected card may have been deleted; fall back to the first one.
                    if let selectedId, !self.items.contains(where: { $0.id == selectedId }) {
                        self.selectedId = self.items.first?.id
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
        guard searchResults == nil, items.count == limit, index >= items.count - Self.pageSize / 2
        else { return }
        limit += Self.pageSize
        startLiveList()
    }

    /// Cancels the search for the previous text and starts one for the current text. An empty
    /// box needs no database read: the live list comes back at once.
    private func startSearch() {
        search?.cancel()
        guard !searchText.isEmpty else {
            searchResults = nil
            selectedId = items.first?.id
            return
        }
        search = Task { [store, searchText] in
            // A timing marker around the whole search, from keystroke to results assigned, so
            // `log show --signpost` and Instruments can measure it against the speed limit.
            let state = Log.timing.beginInterval("Search")
            do {
                let results = try await store.search(searchText, limit: Self.pageSize)
                // A newer keystroke cancelled this search while the database was busy: its
                // results are stale, and the newer search will set its own.
                guard !Task.isCancelled else { return }
                searchResults = results
                selectedId = items.first?.id
                Log.timing.endInterval("Search", state)
                Log.ui.info("search found \(results?.count ?? -1, privacy: .public) items")
            } catch is CancellationError {
                // Cancelled mid-read; nothing to show and nothing wrong.
            } catch {
                Log.ui.error("search failed: \(error, privacy: .public)")
            }
        }
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

    /// Pastes the selected card (Return). `plainText` is whether ⇧ was held.
    func pasteSelected(plainText: Bool) {
        guard let item = items.first(where: { $0.id == selectedId }) else { return }
        paste(item, plainText: plainText)
    }

    /// Pastes the Nth card, 1 to 9, for ⌘1–⌘9. The numbers match the badges on the cards.
    func paste(shortcutNumber: Int, plainText: Bool) {
        guard (1...9).contains(shortcutNumber), items.count >= shortcutNumber else { return }
        paste(items[shortcutNumber - 1], plainText: plainText)
    }

    /// Pastes one card. `plainText` is whether the user asked for it this time (⇧); the
    /// "always plain text" setting makes every paste plain. A failure is logged, not shown:
    /// by then the item is on the clipboard either way, so the user can still press ⌘V.
    func paste(_ item: ClipboardItem, plainText: Bool) {
        let plain = plainText || PasteSettings.alwaysPlainText
        let destination = PasteSettings.destination
        Task {
            do {
                try await pasteService.paste(item, plainText: plain, destination: destination)
            } catch {
                Log.paste.error("paste failed: \(error, privacy: .public)")
            }
        }
    }

    /// Shows macOS's own prompt for the Accessibility permission (the hint's button).
    func requestAccessibility() { pasteService.requestAccessibility() }

    /// Called by the window when the panel comes on screen: the newest card is selected and
    /// search starts empty, the way Paste opens.
    func didShow() {
        selectedId = items.first?.id
        searchText = ""
        isVisible = true
        needsAccessibility =
            PasteSettings.destination == .activeApp && !pasteService.isAccessibilityTrusted
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
