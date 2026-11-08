// The pictures the cards draw, kept in memory. A card asks for its item's thumbnail; if it is
// here, it draws at once; if not, the card draws blank, the thumbnail is read from the database
// in the background (or made on the spot, for an item saved before previews existed) and the
// card fills in a moment later. ≈ an image cache in front of a FlatList, like react-native-
// fast-image's, or Glide's memory cache on Android.
//
// `NSCache` is Apple's in-memory cache: a dictionary that throws things out on its own when
// it holds too many or when memory runs low. The limits keep a scroll through ten thousand
// cards from piling up ten thousand pictures.
import AppKit
import ClipCore
import SwiftUI

@Observable final class ThumbnailCache {
    /// Changes every time a thumbnail lands in the cache. A card reads it through `image(for:)`,
    /// which makes SwiftUI re-draw the card when a thumbnail arrives. (The cache itself is not
    /// observable: NSCache is a plain Objective-C object.)
    private(set) var version = 0

    private let store: Store
    private let enricher: Enricher
    /// Decoded thumbnails, keyed by item id. At most 300 pictures or about 64 MB of PNG bytes,
    /// whichever comes first: a dozen cards are on screen at a time, so 300 covers a lot of
    /// scrolling back and forth without touching the database.
    private let images = NSCache<NSNumber, NSImage>()
    /// Items whose thumbnail is being read right now, so a card redrawn while the read runs
    /// does not start a second one. Also holds items that turned out to have none, so they
    /// are not asked for again on every scroll.
    private var loading: Set<Int64> = []

    init(store: Store, enricher: Enricher) {
        self.store = store
        self.enricher = enricher
        images.countLimit = 300
        images.totalCostLimit = 64 * 1024 * 1024
    }

    /// The item's thumbnail if it is in memory. Otherwise nil, and a background read starts
    /// that re-draws the caller when it lands. Images and files have thumbnails; a link's is
    /// its site's icon, when the page offered one.
    func image(for item: ClipboardItem) -> NSImage? {
        _ = version
        if let image = images.object(forKey: item.id as NSNumber) { return image }
        guard item.kind == .image || item.kind == .file || item.kind == .link, !loading.contains(item.id)
        else { return nil }
        loading.insert(item.id)
        Task { await load(item) }
        return nil
    }

    /// Reads the thumbnail from the database, or makes one for an item that has none yet (a
    /// copy saved before previews existed), decodes it off the main thread and caches it.
    private func load(_ item: ClipboardItem) async {
        do {
            var thumbnail = try await store.thumbnail(for: item.id)
            if thumbnail == nil { thumbnail = try await enricher.enrich(item)?.thumbnail }
            guard let thumbnail, let image = await Self.decode(thumbnail.png) else { return }
            images.setObject(image, forKey: item.id as NSNumber, cost: thumbnail.png.count)
            loading.remove(item.id)
            version += 1
        } catch {
            Log.ui.error("could not load thumbnail \(item.id, privacy: .public): \(error, privacy: .public)")
        }
    }

    /// Decodes a PNG into pixels on a background thread, so a card never waits for it.
    /// (`NSImage(data:)` would decode lazily on first draw, on the main thread, during the
    /// scroll.) `@concurrent` is what moves an async function off the caller's thread.
    @concurrent private static func decode(_ png: Data) async -> NSImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCache: true] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
