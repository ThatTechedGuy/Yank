import Foundation
import GRDB

// The one place that touches the disk: every read and write of the database and of the large
// data files goes through the Store. Everyone else, the capture loop today and any UI that lists
// items, calls these async methods and never sees SQL or GRDB.
//
// Inside, the Store uses GRDB's record API (see Records.swift) and never writes SQL by hand:
// GRDB builds the statements from `filter`, `order`, `insert`, `update` and `deleteAll`. The one
// exception is the full-text search table, where the `MATCH` query goes through GRDB's
// `FTS5Pattern`, because SQL has no column-style way to say "matches these words".
//
// Threading, in one paragraph: `DatabasePool` is GRDB's connection pool. Writes queue up on one
// background thread, one at a time; reads run in parallel on other threads and don't wait for a
// write to finish (SQLite's WAL mode: a write goes to a side log first, so readers keep seeing
// the last committed state). Each `write { db in }` block is one transaction. The `async`
// methods below are what callers await from the main thread, like `await db.insert(...)` with
// Drizzle; the work itself never blocks the UI.
//
// `final class ... : Sendable`: a class (a reference type, shared by pointer) that the compiler
// lets us use from any thread, because every field is a `let` and is itself safe to share.
/// Saves and lists clipboard items. One instance per app.
public final class Store: Sendable {
    private let pool: DatabasePool
    private let files: LargeDataFiles

    /// Opens (or creates) the database in `folder`, runs migrations and removes orphan files.
    /// Runs on the caller's thread; the app calls it on the main thread at launch.
    public init(folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pool = try DatabasePool(path: folder.appending(path: "yank.sqlite").path)
        files = try LargeDataFiles(folder: folder.appending(path: "LargeData"))
        try Migrations.migrator.migrate(pool)
        // A data file that no row points at can only come from a crash in the middle of a save or
        // a delete (see LargeDataFiles). Sweep now, before capture starts, so the folder never
        // grows with leftovers. It is a quick directory listing, so doing it here is fine.
        let (count, fileNames) = try pool.read { db in
            (
                try ClipboardItem.fetchCount(db),
                try ClipboardItemDataRow.fileNames(in: ClipboardItemDataRow.all()).fetchSet(db)
            )
        }
        try files.sweep(keeping: fileNames)
        Log.store.info("opened store at \(folder.path, privacy: .public) with \(count) items")
    }

    // The app's data folder. In a sandboxed app (one macOS keeps inside its own private folder),
    // `.applicationSupportDirectory` resolves to
    // ~/Library/Containers/com.thattechedguy.Yank/Data/Library/Application Support, the
    // sandbox's private home, like an Android app's /data/data/<id>/files. Tests pass a
    // temporary folder instead.
    /// Where the real app keeps its data.
    public static var defaultFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Yank")
    }

    /// Saves a copy as a new item, or moves the existing item with the same content to the top.
    /// Returns the saved item either way. (`@discardableResult` lets a caller ignore the return
    /// value without a compiler warning; the capture loop does use it.)
    @discardableResult
    public func save(_ copy: CapturedCopy) async throws -> ClipboardItem {
        // Kind, fingerprint and card text need no database, so compute them before entering the
        // write block. The one writer thread is then busy only for the actual SQL, and other
        // saves queue behind it for less time.
        let kind = ItemKind.detect(copy.data)
        let fingerprint = DuplicateKey.make(kind: kind, data: copy.data)
        let cardText = CardText.make(kind: kind, data: copy.data)
        // Large data goes to disk *before* the transaction, so a row never points at a file that
        // isn't fully there yet. If the transaction then fails, these files are leftovers; they
        // are removed right away below, or by the sweep at the next launch after a crash.
        // (`try ... ? :` picks the branch first, then runs the `try` in it.)
        let fileNames: [String?] = try copy.data.map { item in
            item.data.count <= LargeDataFiles.inlineLimit ? nil : try files.write(item.data)
        }
        let (item, oldFileNames): (ClipboardItem, [String])
        do {
            (item, oldFileNames) = try await pool.write { db in
                // Repeat copy? Reuse the newest item with the same content instead of adding a
                // duplicate: it keeps its id, title and pinboard, and takes the new time, source
                // app and data. Its old data rows are dropped here; their files are deleted
                // only after this transaction has committed.
                let existing =
                    try ClipboardItem
                    .filter(ClipboardItemColumns.contentFingerprint == fingerprint)
                    .order(ClipboardItemColumns.copiedAt.desc).fetchOne(db)
                let item: ClipboardItem
                var oldFileNames: [String] = []
                if var existing {
                    existing.copiedAt = copy.copiedAt
                    existing.cardText = cardText
                    existing.sourceAppBundleId = copy.sourceApp?.bundleId
                    existing.sourceAppName = copy.sourceApp?.name
                    // `update` writes every column of the row back, matched by `id`.
                    try existing.update(db)
                    item = existing
                    let oldRows = ClipboardItemDataRow.ofItem(item.id)
                    oldFileNames = try ClipboardItemDataRow.fileNames(in: oldRows).fetchAll(db)
                    try oldRows.deleteAll(db)
                } else {
                    // `insertAndFetch` inserts and reads the new row straight back, so the
                    // caller gets the item exactly as stored, with the id the database chose.
                    item = try NewClipboardItem(
                        kind: kind, cardText: cardText, sourceAppBundleId: copy.sourceApp?.bundleId,
                        sourceAppName: copy.sourceApp?.name, createdAt: copy.copiedAt,
                        copiedAt: copy.copiedAt, contentFingerprint: fingerprint
                    ).insertAndFetch(db, as: ClipboardItem.self)
                }
                // One data row per clipboard type, in the source app's order (`position`). Small
                // data goes in the row; large data is already in the file written above, and the
                // row keeps its name. (`enumerated()` gives (index, element) pairs,
                // ≈ `.forEach((d, i) => ...)`.)
                for (position, data) in copy.data.enumerated() {
                    let fileName = fileNames[position]
                    try ClipboardItemDataRow(
                        clipboardItemId: item.id, pasteboardItemIndex: data.pasteboardItemIndex,
                        position: position, type: data.type, data: fileName == nil ? data.data : nil,
                        largeDataFileName: fileName
                    ).insert(db)
                }
                let verb = existing == nil ? "saved" : "moved to top"
                Log.store.info(
                    "\(verb, privacy: .public) item \(item.id, privacy: .public) kind \(kind.rawValue, privacy: .public)"
                )
                return (item, oldFileNames)
            }
        } catch {
            // The transaction was rolled back, so the new files belong to nobody. Remove them now
            // (best effort: `try?` ignores a failure, the sweep catches it later) and pass the
            // error on.
            try? files.delete(fileNames.compactMap { $0 })
            throw error
        }
        // The rows that pointed at the old files are gone for good, so the files can go too.
        try files.delete(oldFileNames)
        return item
    }

    /// Items, newest copied first, one page at a time so a list never loads everything.
    /// ≈ `SELECT * ... ORDER BY copiedAt DESC, id DESC LIMIT ? OFFSET ?`.
    public func items(limit: Int, offset: Int = 0) async throws -> [ClipboardItem] {
        try await pool.read { db in
            try ClipboardItem.newestFirst.limit(limit, offset: offset).fetchAll(db)
        }
    }

    /// The newest `limit` items, delivered now and again every time they change, so the panel
    /// shows a new copy the moment it is saved without asking for the list again.
    ///
    /// This is a live query: GRDB watches the tables the fetch read and re-runs it after every
    /// write that touches them, on its own background thread, then hands the fresh list to
    /// whoever is looping over the result with `for try await`. ≈ Room's `Flow<List<T>>` or a
    /// Supabase subscription. The loop ends when the task running it is cancelled, which also
    /// stops the watching. `removeDuplicates` skips a delivery when a write changed nothing the
    /// list shows (for example, bytes of an item below the limit), so the panel is not redrawn
    /// for nothing. (`some AsyncSequence<...>` hides GRDB's own type: callers only see "a
    /// sequence of item lists that can fail", so the app never has to import GRDB.)
    public func observeItems(limit: Int) -> some AsyncSequence<[ClipboardItem], any Error> {
        ValueObservation
            .tracking { db in try ClipboardItem.newestFirst.limit(limit).fetchAll(db) }
            .removeDuplicates()
            .values(in: pool)
    }

    /// How many items are saved. The menu shows this number.
    public func count() async throws -> Int {
        try await pool.read { db in try ClipboardItem.fetchCount(db) }
    }

    /// All clipboard data of one item, in the source app's order, with large data read from disk.
    public func data(for itemId: Int64) async throws -> [ClipboardItemData] {
        let files = self.files
        return try await pool.read { db in
            try ClipboardItemDataRow.ofItem(itemId).fetchAll(db).map { row in
                // Large data was written to a file at save time and only its name is in the
                // row, so read it back from disk; otherwise the bytes are in the row. One of the
                // two is always set, so the `?? Data()` fallback never runs.
                let data = try row.largeDataFileName.map(files.read) ?? row.data ?? Data()
                return ClipboardItemData(
                    pasteboardItemIndex: row.pasteboardItemIndex, type: row.type, data: data)
            }
        }
    }

    // Only tests call this today: it proves the search index is kept up to date by the triggers
    // in Migrations, so a real search can rely on it. `internal` (Swift's default, written out
    // here on purpose) means tests can see it through `@testable import` but the app cannot.
    /// How many items match a search such as "quart" (a prefix) or "draft report".
    internal func searchHitCount(_ query: String) async throws -> Int {
        // Full-text search has no `filter` equivalent: SQLite's `MATCH` takes a search pattern
        // in its own little language. `FTS5Pattern` builds that pattern safely from the user's
        // words (each word becomes a prefix, so "qua" finds "quarterly"), and `matching` is the
        // query builder's way of applying it. An empty query makes no pattern, so nothing matches.
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return 0 }
        return try await pool.read { db in
            try clipboardItemSearchIndex.all().matching(pattern).fetchCount(db)
        }
    }

    /// Deletes an item, its data rows (SQLite does that by cascade) and its files on disk.
    public func delete(id: Int64) async throws {
        // Rows first, files second: a crash in between leaves an unreferenced file for the sweep,
        // never a row pointing at a missing file.
        let fileNames = try await pool.write { db in
            let names = try ClipboardItemDataRow.fileNames(in: ClipboardItemDataRow.ofItem(id))
                .fetchAll(db)
            try ClipboardItem.deleteOne(db, key: id)
            return names
        }
        try files.delete(fileNames)
    }
}

// Fake history for trying the panel with thousands of items. Only debug builds contain this
// code (`#if DEBUG` ≈ `__DEV__`), so the app you use every day can never run it, and it always
// works on its own database (`seedFolder`), never on your real history. It lives in this file
// because it needs the Store's private database handle: thousands of rows have to go in as one
// transaction, and only Storage/ may talk to GRDB.
#if DEBUG
    extension Store {
        /// Where the fake history lives: a folder next to the real one, so the two never mix.
        public static var seedFolder: URL {
            URL.applicationSupportDirectory.appending(path: "Yank-seed")
        }

        /// Replaces everything in this store with `count` fake items, all small, with a mix of
        /// kinds and apps and times spread over the past, newest first by id. One transaction,
        /// so 100,000 items take a second or two instead of minutes of single saves.
        public func seed(count: Int) async throws {
            try await pool.write { db in
                try ClipboardItem.deleteAll(db)
                let now = Date()
                let apps = ["Safari", "TextEdit", "Terminal", "Notes", "Finder", "Mail"]
                for i in 0..<count {
                    let app = apps[i % apps.count]
                    // Half the items are text; the rest cycle through link, file, colour and
                    // image, so a seeded panel shows every kind of card. The image is a real
                    // one-pixel PNG, so anything that decodes it later works on seeded data too.
                    let (kind, text, type, data): (ItemKind, String, String, Data) =
                        switch i % 8 {
                        case 1:
                            (.link, "https://example.com/pages/\(i)", ClipboardType.url, Data())
                        case 3:
                            (.file, "report-\(i).pdf", ClipboardType.fileURL, Data())
                        case 5:
                            (.color, "#2B59D6", ClipboardType.color, Data())
                        case 7:
                            (.image, "", "public.png", Self.onePixelPNG)
                        default:
                            (
                                .text, "Sample item \(i): meeting moved to 3 pm Thursday.",
                                ClipboardType.plainText, Data()
                            )
                        }
                    // Items 97 seconds apart, so a 100,000-item history spans about four months.
                    let copiedAt = now.addingTimeInterval(-97 * Double(i))
                    let item = try NewClipboardItem(
                        kind: kind, cardText: text, sourceAppBundleId: "com.example.\(app)",
                        sourceAppName: app, createdAt: copiedAt, copiedAt: copiedAt,
                        contentFingerprint: "seed-\(i)"
                    ).insertAndFetch(db, as: ClipboardItem.self)
                    try ClipboardItemDataRow(
                        clipboardItemId: item.id, pasteboardItemIndex: 0, position: 0, type: type,
                        data: data.isEmpty ? Data(text.utf8) : data, largeDataFileName: nil
                    ).insert(db)
                }
            }
            // The rows that pointed at any old large-data files are gone, so the files can go.
            try files.sweep(keeping: [])
            Log.store.info("seeded \(count) fake items")
        }

        /// A valid 1 × 1 PNG (one blue pixel), 70 bytes: the smallest real image a fake item can
        /// carry.
        private static let onePixelPNG = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44,
            0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F,
            0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xD0,
            0x8E, 0xBC, 0xF6, 0x1F, 0x00, 0x04, 0x67, 0x02, 0x5A, 0xFC, 0x60, 0x66, 0xFC, 0x00, 0x00,
            0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
        ])
    }
#endif
