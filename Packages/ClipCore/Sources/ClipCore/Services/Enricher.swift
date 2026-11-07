import Foundation
import os

// Adds to a saved item what the save itself could not: a thumbnail for an image or a file, the
// pixel size of an image, the hex value of a colour. It runs after the save, at low priority,
// so a copy is in the history and on the panel before any decoding starts, and a slow Quick
// Look never delays the next copy. ≈ a background job queued after the insert.
//
// Decoding needs macOS frameworks (ImageIO, Quick Look, AppKit) that this module keeps out, so
// the actual work comes in as a function: the app passes ClipSystem's `Thumbnailer`, a test
// passes a closure that returns whatever preview it likes. The service itself only reads the
// item's bytes, calls that function and saves the answer through the Store.
/// Makes previews for saved items in the background.
public final class Enricher: Sendable {
    /// The function that turns an item and its bytes into a preview. Nil means "nothing to
    /// add" (a text item, a file Quick Look cannot read, an image that does not decode).
    public typealias MakePreview = @Sendable (ClipboardItem, [ClipboardItemData]) async -> CardPreview?

    private let store: Store
    private let makePreview: MakePreview
    /// The work in progress, by item id. A copy made while the panel is open is asked for twice
    /// at once, by the capture path and by the card that appears for it; both wait for the one
    /// task instead of decoding the same bytes twice. `OSAllocatedUnfairLock` guards the dictionary, since
    /// callers come from different threads.
    private let inFlight = OSAllocatedUnfairLock<[Int64: Task<CardPreview?, Error>]>(initialState: [:])

    public init(store: Store, makePreview: @escaping MakePreview) {
        self.store = store
        self.makePreview = makePreview
    }

    /// Makes and saves the item's preview, and returns it. Text and links have no preview to
    /// make, so they return nil without reading any bytes. (`@discardableResult`: the capture
    /// path ignores the return value; the panel uses it to show a thumbnail straight away.)
    @discardableResult
    public func enrich(_ item: ClipboardItem) async throws -> CardPreview? {
        guard item.kind == .image || item.kind == .file || item.kind == .color else { return nil }
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
        guard let preview = await makePreview(item, data) else { return nil }
        try await store.setPreview(preview, for: item.id)
        Log.store.info("enriched item \(item.id, privacy: .public)")
        return preview
    }

    /// `enrich`, started in the background at low priority and never awaited: what the capture
    /// path calls after each save. `.utility` tells the system this can wait behind anything
    /// the user is looking at. A failure is logged, not shown: the item is saved either way.
    public func enrichInBackground(_ item: ClipboardItem) {
        Task(priority: .utility) {
            do {
                try await enrich(item)
            } catch {
                Log.store.error(
                    "could not enrich item \(item.id, privacy: .public): \(error, privacy: .public)")
            }
        }
    }
}
