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
    /// copy arriving at the front of the list. A preview belongs to the selected card, so it
    /// closes when the selection moves.
    var selectedId: Int64? {
        didSet { if selectedId != oldValue { closePreview() } }
    }
    /// Whether the large preview (text, link, colour) is open above the selected card.
    var showsLargePreview = false
    /// The file Quick Look is showing for the selected image or file, or nil when it is closed.
    /// SwiftUI's `.quickLookPreview` opens and closes the Quick Look panel as this changes.
    var quickLookURL: URL?
    /// What is typed in the search box. Every change starts a search for the new text.
    /// (`didSet` runs after the value is stored, ≈ a setter hook; `oldValue` is the previous
    /// text. SwiftUI's binding sets it again on focus changes, so same-text sets are ignored.)
    var searchText = "" {
        didSet { if searchText != oldValue { startSearch() } }
    }
    /// Which tab the panel is on (History or a pinboard) and the kind and date it is narrowed
    /// to. Both the live list and the search read it, so a change restarts both. It is kept
    /// while the panel is hidden: the panel reopens where it was left, like a browser tab.
    var filter = ItemFilter() {
        didSet {
            guard filter != oldValue else { return }
            limit = Self.pageSize
            startLiveList()
            startSearch()
        }
    }
    /// The pinboards, in tab order, kept fresh by a live query like the items.
    private(set) var pinboards: [Pinboard] = []
    /// The card ⌘P or "Pin to" is choosing a pinboard for: a small chooser opens on it. Nil
    /// when none is open. (Only used when there is more than one pinboard to choose from.)
    var pinChooserItemId: Int64?
    /// Whether the "New Pinboard" name prompt is up, and which card to pin to the new board
    /// once it exists (nil: just create it). The view shows the prompt while this is non-nil.
    var newPinboardPrompt: NewPinboardPrompt?
    /// The pinboard whose Rename prompt, or Delete confirmation, is up; nil when none is.
    var renamingPinboard: Pinboard?
    var deletingPinboard: Pinboard?
    /// True while any of the small popovers above is open. The keyboard is then in that
    /// popover, so the panel leaves Return, Space, Tab and the arrow keys to it: Return must
    /// finish a name, not paste a card.
    var isPrompting: Bool {
        pinChooserItemId != nil || newPinboardPrompt != nil || renamingPinboard != nil
            || deletingPinboard != nil
    }
    /// Whether the panel is on screen. The view uses it to put the cursor in search on open.
    private(set) var isVisible = false
    /// True when Return would paste into the active app but macOS does not let Yank press ⌘V:
    /// the panel then shows a hint. Checked each time the panel opens, so granting the
    /// permission in System Settings is noticed on the next ⇧⌘V without a restart.
    private(set) var needsAccessibility = false

    let store: Store
    private let pasteService: PasteService
    /// The task running the live query. Cancelling it stops the query; a new one starts when
    /// the limit changes.
    private var liveList: Task<Void, Never>?
    /// The task keeping `pinboards` fresh. Runs for as long as the model lives.
    private var pinboardList: Task<Void, Never>?
    /// The search running for the current text, if any. Cancelled by the next keystroke.
    private var search: Task<Void, Never>?
    /// How many items the live query asks for. Grows as the user scrolls towards the end.
    private var limit = pageSize

    init(store: Store, pasteService: PasteService) {
        self.store = store
        self.pasteService = pasteService
        startLiveList()
        startPinboardList()
    }

    /// Starts (or restarts, with the current limit and filter) the live query that keeps
    /// `items` fresh. It runs all the time, not only while the panel is open, so the cards are
    /// already loaded when the panel appears and opening it costs no database read.
    private func startLiveList() {
        liveList?.cancel()
        // `for try await` loops over each delivery as it arrives, like `for await` over an
        // async iterator in JS. The body runs on the main thread, because this class does.
        liveList = Task { [store, limit, filter] in
            do {
                for try await items in store.observeItems(matching: filter, limit: limit) {
                    self.liveItems = items
                    // The selected card may have been deleted, pinned away, or belong to the
                    // tab before a switch; fall back to the first one.
                    if !self.items.contains(where: { $0.id == selectedId }) {
                        self.selectedId = self.items.first?.id
                    }
                }
            } catch {
                Log.ui.error("the panel's live list stopped: \(error, privacy: .public)")
            }
        }
    }

    /// Starts the live query that keeps the tab row's pinboards fresh. If the tab the panel is
    /// on is deleted (from the menu, or by the database being erased), it falls back to History.
    private func startPinboardList() {
        pinboardList = Task { [store] in
            do {
                for try await pinboards in store.observePinboards() {
                    self.pinboards = pinboards
                    if case .pinboard(let id) = filter.list, !pinboards.contains(where: { $0.id == id }) {
                        filter.list = .history
                    }
                }
            } catch {
                Log.ui.error("the panel's pinboard list stopped: \(error, privacy: .public)")
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
        search = Task { [store, searchText, filter] in
            // A timing marker around the whole search, from keystroke to results assigned, so
            // `log show --signpost` and Instruments can measure it against the speed limit.
            let state = Log.timing.beginInterval("Search")
            do {
                let results = try await store.search(searchText, matching: filter, limit: Self.pageSize)
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

    /// Whether a preview of any kind is open.
    var showsPreview: Bool { showsLargePreview || quickLookURL != nil }

    /// Space: opens the selected card's preview, or closes the one that is open. Images and
    /// files go to Quick Look, which needs a file on disk (the Store writes one, off the main
    /// thread); everything else opens the large preview.
    func togglePreview() {
        guard !showsPreview else {
            closePreview()
            return
        }
        guard let item = items.first(where: { $0.id == selectedId }) else { return }
        guard item.kind == .image || item.kind == .file else {
            showsLargePreview = true
            return
        }
        Task { [store] in
            do {
                let url = try await store.quickLookFile(for: item)
                // Still the same card? The user may have moved on while the file was written.
                guard selectedId == item.id else { return }
                quickLookURL = url
            } catch {
                Log.ui.error("could not write the Quick Look file: \(error, privacy: .public)")
            }
        }
    }

    /// Closes whichever preview is open. Esc does this before it closes the panel.
    func closePreview() {
        showsLargePreview = false
        quickLookURL = nil
    }

    /// The item's whole text, for the large preview. The card only carries the first 200
    /// characters; this reads the saved bytes. Nil when they cannot be read.
    func fullText(for item: ClipboardItem) async -> String? {
        let data = try? await store.data(for: item.id)
        return data?.first { $0.type == ClipboardType.plainText }?.text
    }

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
    /// Closes whichever popover is open (Esc, or the panel hiding).
    func closePrompts() {
        pinChooserItemId = nil
        newPinboardPrompt = nil
        renamingPinboard = nil
        deletingPinboard = nil
    }

    func didHide() {
        isVisible = false
        closePreview()
        closePrompts()
        if limit != Self.pageSize {
            limit = Self.pageSize
            startLiveList()
        }
    }
}
