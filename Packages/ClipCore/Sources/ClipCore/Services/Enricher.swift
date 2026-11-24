import Foundation
import os

// The decoding frameworks (ImageIO, Quick Look, Vision, LinkPresentation) stay out of this module,
// so the work comes in as functions and a port. Links are the one place Yank goes on the network:
// nothing is fetched with link previews off, or ever for an address on this Mac or the local network.
/// Makes previews for saved items in the background.
public final class Enricher: Sendable {
    /// The function that turns an item and its bytes into a preview. Nil means "nothing to
    /// add" (a text item, a file Quick Look cannot read, an image that does not decode).
    public typealias MakePreview = @Sendable (ClipboardItem, [ClipboardItemData]) async -> CardPreview?
    /// The function that reads the words in an image's bytes. Nil means none were found.
    public typealias RecognizeText = @Sendable ([ClipboardItemData]) async -> String?
    /// The function that asks the model for a copy's labels, choosing the category from the
    /// list it is given. Throws `ModelNotReady` when the model cannot answer for now, any other
    /// error when it cannot answer for this text.
    public typealias AskModel =
        @Sendable (_ text: String, _ categories: [ItemCategory]) async throws -> Labels

    private let store: Store
    private let makePreview: MakePreview
    private let recognizeText: RecognizeText?
    private let linkFetcher: (any LinkFetching)?
    /// Asked right before each fetch, so flipping the switch in Settings takes effect at once.
    private let linkPreviewsEnabled: @Sendable () -> Bool
    private let askModel: AskModel?
    /// Asked right before each model call: false while the switch is off or the model is
    /// unavailable, and then the model is never called.
    private let labelsEnabled: @Sendable () -> Bool
    /// How long the label run waits before asking again when the model is not ready.
    private let retryDelay: Duration
    /// Whether a run is working through the label queue, and whether it was asked to go round
    /// again (something was queued while it ran), so one run goes at a time and no ask is lost.
    private let labelling = OSAllocatedUnfairLock(initialState: (running: false, again: false))
    /// The work in progress, by item id. A copy made while the panel is open is asked for twice
    /// at once, by the capture path and by the card that appears for it; both wait for the one
    /// task instead of decoding the same bytes (or fetching the same page) twice.
    private let inFlight = OSAllocatedUnfairLock<[Int64: Task<CardPreview?, Error>]>(initialState: [:])

    /// `recognizeText` and `linkFetcher` are optional: without them the Enricher makes thumbnails
    /// only. `linkPreviewsEnabled` only matters when there is a fetcher.
    public init(
        store: Store, makePreview: @escaping MakePreview, recognizeText: RecognizeText? = nil,
        linkFetcher: (any LinkFetching)? = nil,
        linkPreviewsEnabled: @escaping @Sendable () -> Bool = { true }, askModel: AskModel? = nil,
        labelsEnabled: @escaping @Sendable () -> Bool = { true }, retryDelay: Duration = .seconds(60)
    ) {
        self.store = store
        self.makePreview = makePreview
        self.recognizeText = recognizeText
        self.linkFetcher = linkFetcher
        self.linkPreviewsEnabled = linkPreviewsEnabled
        self.askModel = askModel
        self.labelsEnabled = labelsEnabled
        self.retryDelay = retryDelay
    }

    /// Makes and saves the item's preview, and returns it; nil for text, and for a link without a
    /// fetcher. A link whose page title is already saved is not fetched again: opening a page can
    /// use up a one-time link, so a repeat copy must not open it a second time.
    @discardableResult
    public func enrich(_ item: ClipboardItem) async throws -> CardPreview? {
        switch item.kind {
        case .text: return nil
        case .link where linkFetcher == nil || item.linkPageTitle != nil: return nil
        default: break
        }
        let task = inFlight.withLock { tasks in
            if let task = tasks[item.id] { return task }
            let task = Task {
                defer { inFlight.withLock { $0[item.id] = nil } }
                return try await makeAndSave(item)
            }
            tasks[item.id] = task
            return task
        }
        return try await task.value
    }

    private func makeAndSave(_ item: ClipboardItem) async throws -> CardPreview? {
        // shortcut: this loads every type of the item, so a 200 MB TIFF next to a PNG is read
        // too; add a per-type read to Store if that ever shows up in memory.
        let data = try await store.data(for: item.id)
        let preview =
            item.kind == .link ? try await linkPreview(item, data) : await makePreview(item, data)
        guard let preview else { return nil }
        try await store.setPreview(preview, for: item.id)
        Log.store.info("enriched item \(item.id, privacy: .public)")
        return preview
    }

    /// The title and icon of the page a link points at, or nil when previews are off, the
    /// address is local, or the copy holds no usable address.
    private func linkPreview(_ item: ClipboardItem, _ data: [ClipboardItemData]) async throws -> CardPreview?
    {
        guard let linkFetcher, linkPreviewsEnabled() else { return nil }
        guard let url = URL(string: data.linkAddress) else { return nil }
        if LocalAddress.isLocal(url) {
            Log.store.info("skipped: local address, item \(item.id, privacy: .public)")
            return nil
        }
        let page = try await linkFetcher.fetch(url)
        return CardPreview(
            thumbnail: page.icon.map {
                CardThumbnail(clipboardItemId: item.id, png: $0.png, width: $0.width, height: $0.height)
            },
            linkPageTitle: page.title)
    }

    /// Reads the words in an image and saves them, so search finds a screenshot by what it says.
    /// Kept apart from `enrich`, which the panel waits on for a card's thumbnail: reading text
    /// takes a good part of a second. Nothing happens for other kinds, or without a recognizer,
    /// or when the image was read before (a repeat copy has the same bytes).
    public func recognizeText(in item: ClipboardItem) async throws {
        guard item.kind == .image, item.imageText == nil, let recognizeText else { return }
        // Reads the bytes a second time after `enrich`, rather than keeping them around between
        // the two steps; an image is read from disk in milliseconds.
        let data = try await store.data(for: item.id)
        // "" rather than nothing for no words: nil means "not read yet", and a photo with no
        // words would otherwise be read again on every repeat copy.
        let text = await recognizeText(data) ?? ""
        try await store.setPreview(CardPreview(imageText: text), for: item.id)
        Log.store.info("read text in item \(item.id, privacy: .public)")
    }

    /// `enrich` and then `recognizeText`, started in the background at low priority: what the
    /// capture path calls after each save, without waiting on the task it gets back (tests do).
    /// A failure is logged, not shown: the item is saved either way. A repeat copy already has
    /// its preview, so nothing is decoded, read or fetched again for it.
    // shortcut: "has a preview" means "has a thumbnail", so a link whose page gave neither a
    // title nor an icon is fetched again on a repeat copy; remember a failed fetch on the item
    // if a one-time link ever gets used up that way.
    @discardableResult
    public func enrichInBackground(_ item: ClipboardItem) -> Task<Void, Never> {
        Task(priority: .utility) {
            do {
                if try await store.thumbnail(for: item.id) == nil { try await enrich(item) }
                try await recognizeText(in: item)
            } catch {
                Log.store.error(
                    "could not enrich item \(item.id, privacy: .public): \(error.logDescription, privacy: .public)"
                )
            }
            // The save (or the words just read) put the item on the label queue. Not awaited: the
            // link card waits on this task for its icon, and must not wait for the model too.
            labelInBackground()
        }
    }

    /// Works through the label queue at background priority, one item at a time, until it is
    /// empty or labelling is turned off. The app calls it at launch, after each copy, and when
    /// the switch or the category list changes. Returns nil when a run is already going: that
    /// run picks up whatever was queued.
    @discardableResult
    public func labelInBackground() -> Task<Void, Never>? {
        guard let askModel else { return nil }
        let starts = labelling.withLock { state in
            guard !state.running else {
                state.again = true
                return false
            }
            state.running = true
            return true
        }
        guard starts else { return nil }
        return Task(priority: .background) { await labelQueue(with: askModel) }
    }

    private func labelQueue(with askModel: AskModel) async {
        repeat {
            do {
                while labelsEnabled(), let (item, text) = try await store.nextToLabel() {
                    try await label(item, text, with: askModel)
                }
            } catch {
                Log.store.error("labelling stopped: \(error.logDescription, privacy: .public)")
            }
        } while labelling.withLock { state in
            // Asked again during the run: go round once more, else the run ends.
            if state.again {
                state.again = false
                return true
            }
            state.running = false
            return false
        }
    }

    /// One model call and its save. Read fresh each time, so an edit to the list counts from the
    /// next item. Credential is not offered (only its patterns set it), nor a category with no
    /// description yet: one just added in Settings would otherwise catch items while it is named.
    private func label(_ item: ClipboardItem, _ text: String, with askModel: AskModel) async throws {
        let categories = try await store.categories().filter {
            $0.id != ItemCategory.credentialId && !$0.about.isEmpty
        }
        let labels: Labels
        do {
            labels = try await askModel(text, categories)
        } catch is ModelNotReady {
            // The item stays first in the queue, so the run asks for it again after the wait.
            // shortcut: a fixed wait however long the model stays away; back off if the retries
            // ever show up in energy use.
            Log.store.notice("model not ready for item \(item.id, privacy: .public), asking again later")
            try await Task.sleep(for: retryDelay)
            return
        } catch {
            // About this text (a refusal, say): asking again would get the same answer. It is
            // tried again when a category change queues it.
            Log.store.error(
                "could not label item \(item.id, privacy: .public): \(error.logDescription, privacy: .public)"
            )
            try await store.dropFromLabelQueue(itemId: item.id)
            return
        }
        let language = Language.all.contains(labels.language) ? labels.language : Language.none
        // A title only where the first line says little: code, and text longer than about what a
        // card shows (200 characters).
        let words = labels.title.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        let wantsTitle = language != Language.none || text.count > 200
        try await store.setLabels(
            categoryId: categories.first { $0.name == labels.category }?.id ?? ItemCategory.otherId,
            language: language, title: wantsTitle && !words.isEmpty ? words : nil, for: item.id)
        Log.store.info("labelled item \(item.id, privacy: .public)")
    }
}
