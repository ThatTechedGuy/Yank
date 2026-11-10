// The pictures the cards draw, kept in memory. A card whose thumbnail is not here draws blank
// while it is read from the database (or made, for an item that has none yet) and fills in a
// moment later.
import AppKit
import ClipCore
import SwiftUI

@Observable final class ThumbnailCache {
    /// Changes every time a thumbnail lands in the cache. A card reads it through `image(for:)`,
    /// which makes SwiftUI re-draw the card when a thumbnail arrives; NSCache is not observable.
    private(set) var version = 0

    private let store: Store
    private let enricher: Enricher
    /// Decoded thumbnails, keyed by item id. At most 300 pictures or about 64 MB of decoded
    /// pixels (some 60 full-size thumbnails), whichever comes first: a dozen cards are on
    /// screen at a time, so that covers a lot of scrolling back and forth without touching
    /// the database.
    private let images = NSCache<NSNumber, NSImage>()
    /// Items whose thumbnail is being read right now, so a card redrawn while the read runs
    /// does not start a second one. Also holds items that turned out to have none, so they
    /// are not asked for again on every scroll. Not observed: `image(for:)` changes it while a
    /// card is being drawn, and `version` is what tells the card to draw again.
    @ObservationIgnored private var loading: Set<Int64> = []

    init(store: Store, enricher: Enricher) {
        self.store = store
        self.enricher = enricher
        images.countLimit = 300
        images.totalCostLimit = 64 * 1024 * 1024
    }

    /// The item's thumbnail if it is in memory. Otherwise nil, and a background read starts
    /// that re-draws the caller when it lands. A link's thumbnail is its site's icon.
    func image(for item: ClipboardItem) -> NSImage? {
        if let image = images.object(forKey: item.id as NSNumber) { return image }
        guard item.kind == .image || item.kind == .file || item.kind == .link, !loading.contains(item.id)
        else { return nil }
        // Read here, not at the top: only a card that is still waiting for its picture needs
        // to draw again when one lands. A text card never does.
        _ = version
        loading.insert(item.id)
        Task { await load(item) }
        return nil
    }

    /// Drops the item's picture, for when its bytes were replaced in the editor: the next draw
    /// reads the new thumbnail, or makes one, instead of showing the old picture.
    func forget(_ id: Int64) {
        images.removeObject(forKey: id as NSNumber)
        loading.remove(id)
        version += 1
    }

    /// Starts the item's preview in the background, as every new or edited item needs. A link
    /// card drawn before its page was fetched found no icon, and `load` does not ask twice,
    /// so once the fetch is done the card is made to ask again.
    func enrichInBackground(_ item: ClipboardItem) {
        let enriching = enricher.enrichInBackground(item)
        guard item.kind == .link else { return }
        Task {
            await enriching.value
            forget(item.id)
        }
    }

    /// Reads the thumbnail from the database, or makes one for an item that has none yet, and
    /// caches the image.
    private func load(_ item: ClipboardItem) async {
        do {
            var thumbnail = try await store.thumbnail(for: item.id)
            // A link with no saved icon is left alone: the capture path already asked its page,
            // and fetching on every launch could use up a one-time link.
            if thumbnail == nil, item.kind != .link {
                thumbnail = try await enricher.enrich(item)?.thumbnail
            }
            guard let thumbnail, let image = await Self.decode(thumbnail.png) else { return }
            // The cost is the decoded pixels, four bytes each, not the PNG they came from.
            images.setObject(
                image, forKey: item.id as NSNumber, cost: thumbnail.width * thumbnail.height * 4)
            loading.remove(item.id)
            version += 1
        } catch {
            // A passing error (a busy database, say) must not blank the card for good: the
            // next draw asks again.
            loading.remove(item.id)
            Log.ui.error(
                "could not load thumbnail \(item.id, privacy: .public): \(error.logDescription, privacy: .public)"
            )
        }
    }

    /// Decodes a picture into pixels off the main thread, so a card never waits for it:
    /// `NSImage(data:)` would decode lazily on first draw, on the main thread, during the
    /// scroll. The editor uses it for its picture too.
    @concurrent static func decode(_ png: Data) async -> NSImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
