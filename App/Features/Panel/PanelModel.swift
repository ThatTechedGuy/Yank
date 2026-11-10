// The panel's state, and the only thing that talks to the Store for the panel. A live query
// keeps the list fresh, so a copy made while the panel is open appears on its own; typing in
// search swaps it for search results, and the live list keeps running underneath.
import ClipCore
import SwiftUI

@Observable final class PanelModel {
    /// How many items the live list asks for at first, and how many more each time the user
    /// nears the end. Far more than fit on any screen.
    static let pageSize = 200

    /// The cards on screen: the search results while something is typed, otherwise the live list.
    var items: [ClipboardItem] { searchResults ?? liveItems }
    /// How many cards the row holds, as VoiceOver says it in "Card 1 of 20": the number, or
    /// "200 or more" when the row holds a full page, so more history (or more matches) may be
    /// waiting beyond it. Counting the whole history would take another query on every change.
    var listSizeDescription: String {
        let isFull = searchResults.map { $0.count == Self.pageSize } ?? (liveItems.count == limit)
        return isFull ? "\(items.count) or more" : "\(items.count)"
    }
    /// The newest items, kept fresh by the live query. Only the first `limit` of the history.
    private(set) var liveItems: [ClipboardItem] = []
    /// The items matching `searchText`, or nil when the box is empty or holds too little to
    /// search (one letter, only spaces or punctuation): the full list shows then.
    // shortcut: results are a snapshot, a copy made while they show does not appear in them,
    // and they are capped at one page with no paging; revisit if either is ever noticed.
    private var searchResults: [ClipboardItem]?
    /// The selected cards: a lead card the keys move, and possibly more (⇧← ⇧→, ⌘-click, ⌘A).
    /// Ids, not indexes, so the selection survives a new copy arriving at the front of the
    /// list. A preview closes when the lead moves; a prompt closes with any change.
    var selection = CardSelection() {
        didSet {
            guard selection != oldValue else { return }
            if selection.lead != oldValue.lead { closePreview() }
            prompt = nil
        }
    }
    /// The lead card's id, or nil. Setting it selects that one card alone.
    var selectedId: Int64? {
        get { selection.lead }
        set { selection.select(newValue) }
    }
    /// The small dialog open on a card, if any. One value, so only one can be up at a time,
    /// and the row knows which card to anchor it to.
    var prompt: CardPrompt?
    /// File cards whose file has gone since the copy. Filled in as cards come on screen (each
    /// card checks its own file); such a card says so and cannot be pasted or dragged.
    var missingFileIds: Set<Int64> = []
    /// Whether the large preview (text, link, colour) is open above the selected card.
    var showsLargePreview = false
    /// The file Quick Look is showing for the selected image or file, or nil when it is closed.
    var quickLookURL: URL?
    /// What is typed in the search box. Every change starts a search for the new text;
    /// SwiftUI's binding sets it again on focus changes, so same-text sets are ignored.
    var searchText = "" {
        didSet { if searchText != oldValue { startSearch() } }
    }
    /// Which tab the panel is on (History or a pinboard) and the kind and date it is narrowed
    /// to. A change restarts the live list and the search. It is kept while the panel is
    /// hidden, so the panel reopens where it was left.
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
    /// The card the pinboard chooser (⌘P or "Pin to") is open on, or nil. Only used when
    /// there is more than one pinboard to choose from.
    var pinChooserItemId: Int64?
    /// Non-nil while the "New Pinboard" name prompt is up; it holds the card to pin to the new
    /// board, if any.
    var newPinboardPrompt: NewPinboardPrompt?
    /// The pinboard whose Rename prompt, or Delete confirmation, is up; nil when none is.
    var renamingPinboard: Pinboard?
    var deletingPinboard: Pinboard?
    /// True while any of the small popovers above is open. The keyboard is then in that
    /// popover, so the panel leaves Return, Space, Tab and the arrow keys to it: Return must
    /// finish a name, not paste a card.
    var isPrompting: Bool {
        pinChooserItemId != nil || newPinboardPrompt != nil || renamingPinboard != nil
            || deletingPinboard != nil || prompt != nil
    }
    /// Whether the panel is on screen. The view uses it to put the cursor in search on open.
    private(set) var isVisible = false
    /// True when Return would paste into the active app but macOS does not let Yank press ⌘V:
    /// the panel then shows a hint. Checked each time the panel opens, so granting the
    /// permission is noticed without a restart.
    private(set) var needsAccessibility = false

    let store: Store
    private let pasteService: PasteService
    /// "Add to Stack" in a card's menu. Set by the app model, which owns the paste stack.
    var addToStack: (ClipboardItem) -> Void = { _ in }
    /// "Edit" in a card's menu, ⌘E, and ⌘N for a new text item (nil). Set by the app model,
    /// which owns the editor window.
    var openEditor: (ClipboardItem?) -> Void = { _ in }
    /// The task running the live query; restarted when the limit or the filter changes.
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
    /// `items` fresh. It runs all the time, not only while the panel is open, so opening the
    /// panel costs no database read.
    private func startLiveList() {
        liveList?.cancel()
        liveList = Task { [store, limit, filter] in
            do {
                for try await items in store.observeItems(matching: filter, limit: limit) {
                    self.liveItems = items
                    // Selected cards may have been deleted, pinned away, or belong to the tab
                    // before a switch: they leave the selection, and the first card takes
                    // over if the lead went.
                    self.selection.keep(in: self.items.map(\.id))
                }
            } catch {
                Log.ui.error("the panel's live list stopped: \(error.logDescription, privacy: .public)")
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
                Log.ui.error("the panel's pinboard list stopped: \(error.logDescription, privacy: .public)")
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

    /// Reads the search results again after the user changed a card in them (deleted, renamed,
    /// pinned), since the results are a snapshot. The selection stays where it is if it can.
    func refreshSearch() {
        if searchResults != nil { startSearch(keepingSelection: true) }
    }

    /// Cancels the search for the previous text and starts one for the current text, so a slow
    /// search can never overwrite a newer one. An empty box needs no database read. New text
    /// selects the first result; `keepingSelection` is for a refresh of the same text.
    private func startSearch(keepingSelection: Bool = false) {
        search?.cancel()
        guard !searchText.isEmpty else {
            searchResults = nil
            selectedId = items.first?.id
            return
        }
        search = Task { [store, searchText, filter] in
            // Signposted from keystroke to results assigned, so `log show --signpost` and
            // Instruments can measure the search against the speed limit.
            let state = Log.timing.beginInterval("Search")
            defer { Log.timing.endInterval("Search", state) }
            do {
                let results = try await store.search(searchText, matching: filter, limit: Self.pageSize)
                // A newer keystroke cancelled this search while the database was busy.
                guard !Task.isCancelled else { return }
                searchResults = results
                if keepingSelection {
                    selection.keep(in: items.map(\.id))
                } else {
                    selectedId = items.first?.id
                }
                Log.ui.info("search found \(results?.count ?? -1, privacy: .public) items")
            } catch is CancellationError {
                // Cancelled mid-read; nothing to show and nothing wrong.
            } catch {
                Log.ui.error("search failed: \(error.logDescription, privacy: .public)")
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

    /// ⇧→ (step 1) or ⇧← (step -1): grows or shrinks the selection by one card.
    func extendSelection(by step: Int) { selection.extend(by: step, in: items.map(\.id)) }

    /// ⌘-click: adds the card to the selection, or takes it out.
    func toggleSelection(of id: Int64) { selection.toggle(id) }

    /// ⌘A: selects every card the panel shows.
    func selectAll() { selection.selectAll(in: items.map(\.id)) }

    /// The selected cards, left to right: the order a paste or a drag of several uses.
    var selectedItems: [ClipboardItem] { items.filter { selection.contains($0.id) } }

    /// Return: pastes the selected cards, in order. `plainText` is whether ⇧ was held.
    func pasteSelected(plainText: Bool) {
        paste(selectedItems, plainText: plainText)
    }

    /// Pastes the Nth card, 1 to 9, for ⌘1–⌘9. The numbers match the badges on the cards.
    func paste(shortcutNumber: Int, plainText: Bool) {
        guard (1...9).contains(shortcutNumber), items.count >= shortcutNumber else { return }
        paste(items[shortcutNumber - 1], plainText: plainText)
    }

    /// Pastes one card. `plainText` is whether the user asked for it this time (⇧); the
    /// "always plain text" setting makes every paste plain.
    func paste(_ item: ClipboardItem, plainText: Bool) {
        paste([item], plainText: plainText)
    }

    /// Pastes the cards left to right, to where the "Paste items" setting says unless
    /// `destination` says otherwise ("Copy" in the menu: clipboard only). A file card whose
    /// file is gone stops the whole paste before anything is written. A failure is logged, not
    /// shown: by then the item is on the clipboard either way, so the user can still press ⌘V.
    func paste(_ items: [ClipboardItem], plainText: Bool, destination: PasteDestination? = nil) {
        guard !items.isEmpty else { return }
        let plain = plainText || PasteSettings.alwaysPlainText
        let destination = destination ?? PasteSettings.destination
        Task {
            do {
                try await pasteService.paste(items, plainText: plain, destination: destination)
            } catch PasteError.fileNoLongerExists {
                // A card that was never on screen has not had its file checked, so mark it now.
                for item in items where item.kind == .file { await checkFile(of: item) }
                Log.paste.notice("paste refused: a file no longer exists")
            } catch {
                Log.paste.error("paste failed: \(error.logDescription, privacy: .public)")
            }
        }
    }

    /// Shows macOS's own prompt for the Accessibility permission (the hint's button).
    func requestAccessibility() { pasteService.requestAccessibility() }

    /// Whether a preview of any kind is open.
    var showsPreview: Bool { showsLargePreview || quickLookURL != nil }

    /// Space: opens the selected card's preview, or closes the one that is open. Images and
    /// files go to Quick Look, which needs a file on disk (the Store writes one); everything
    /// else opens the large preview.
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
                // The user may have moved on, or pasted, while the file was written; Quick Look
                // must not pop up over their app.
                guard isVisible, selectedId == item.id else { return }
                quickLookURL = url
            } catch {
                Log.ui.error("could not write the Quick Look file: \(error.logDescription, privacy: .public)")
            }
        }
    }

    /// Closes whichever preview is open. Esc does this before it closes the panel.
    func closePreview() {
        showsLargePreview = false
        quickLookURL = nil
    }

    /// The item's whole text, for the large preview: the card only carries the first 200
    /// characters. Nil when the saved bytes cannot be read.
    func fullText(for item: ClipboardItem) async -> String? {
        let data = try? await store.data(for: item.id)
        return data?.first { $0.type == ClipboardType.plainText }?.text
    }

    /// Called by the window when the panel comes on screen: the newest card is selected and
    /// search starts empty.
    func didShow() {
        selectedId = items.first?.id
        searchText = ""
        isVisible = true
        needsAccessibility =
            PasteSettings.destination == .activeApp && !pasteService.isAccessibilityTrusted
    }

    /// Closes whichever popover is open (Esc, or the panel hiding).
    func closePrompts() {
        pinChooserItemId = nil
        newPinboardPrompt = nil
        renamingPinboard = nil
        deletingPinboard = nil
        prompt = nil
    }

    /// Called by the window when the panel leaves the screen. A list that grew while scrolling
    /// shrinks back to one page, so the live query does little work while the panel is hidden.
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
