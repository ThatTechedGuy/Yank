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
/// Saves, lists and searches clipboard items. One instance per app.
public final class Store: Sendable {
    private let pool: DatabasePool
    private let files: LargeDataFiles

    /// Opens (or creates) the database in `folder`, runs migrations and removes orphan files.
    /// Runs on the caller's thread; the app calls it on the main thread at launch.
    public init(folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var configuration = Configuration()
        #if DEBUG
            // In a debug build, log every SQL statement the database runs, with how long it took,
            // under the "sql" category. It is the only way to see the SQL GRDB builds from the
            // record calls below. `prepareDatabase` runs once for each connection the pool opens,
            // and `trace` asks SQLite to call back after each statement (`.profile` = with its
            // duration). The logged SQL is the statement as prepared, with `?` where the values
            // go, so clipboard contents never reach the log; that is why it can be public.
            // SQLite measures the duration with a millisecond clock, so it is logged as whole
            // milliseconds; "0 ms" means under one.
            configuration.prepareDatabase { db in
                db.trace(options: .profile) { event in
                    guard case .profile(let statement, let duration) = event else { return }
                    Log.sql.info(
                        "\(duration * 1000, format: .fixed(precision: 0), privacy: .public) ms \(statement.sql, privacy: .public)"
                    )
                }
            }
        #endif
        pool = try DatabasePool(
            path: folder.appending(path: "yank.sqlite").path, configuration: configuration)
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
        let cardDetail = CardDetail.make(kind: kind, data: copy.data)
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
                    // A detail the save cannot compute (an image's size) is left as the
                    // Enricher set it last time: the bytes are the same, so it still holds.
                    existing.cardDetail = cardDetail ?? existing.cardDetail
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
                        kind: kind, cardText: cardText, cardDetail: cardDetail,
                        sourceAppBundleId: copy.sourceApp?.bundleId,
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

    /// Moves an item to the top of the history by giving it a new "last copied" time: what a
    /// paste from the panel does, so the item you just used is the first card next time. Only
    /// the time changes; the data rows and files stay as they are. The live list (`observeItems`)
    /// sees the write and delivers the new order on its own.
    public func moveToTop(id: Int64) async throws {
        try await moveToTop(ids: [id])
    }

    /// Moves several items to the top in one transaction, keeping their order: the first id
    /// ends up newest. Each gets a time one millisecond older than the one before, because
    /// the column keeps milliseconds and two items with the same time would fall back to id
    /// order.
    public func moveToTop(ids: [Int64]) async throws {
        let now = Date()
        // `updateAll` on a filtered request is GRDB's "UPDATE ... SET ... WHERE": one statement,
        // no need to fetch the row first. It returns how many rows changed (0 if the item was
        // deleted meanwhile), which nobody needs here, hence the `_ =`.
        try await pool.write { db in
            for (offset, id) in ids.enumerated() {
                _ = try ClipboardItem.filter(key: id)
                    .updateAll(db, [ClipboardItemColumns.copiedAt.set(to: now - Double(offset) / 1000)])
            }
        }
    }

    /// Items, newest copied first, one page at a time so a list never loads everything.
    /// ≈ `SELECT * ... ORDER BY copiedAt DESC, id DESC LIMIT ? OFFSET ?`.
    public func items(limit: Int, offset: Int = 0) async throws -> [ClipboardItem] {
        try await pool.read { db in
            try ClipboardItem.newestFirst.limit(limit, offset: offset).fetchAll(db)
        }
    }

    /// The newest `limit` items that match `filter` (History or a pinboard, a kind, a date
    /// range; the default is all of History), delivered now and again every time they change,
    /// so the panel shows a new copy the moment it is saved without asking for the list again.
    ///
    /// This is a live query: GRDB watches the tables the fetch read and re-runs it after every
    /// write that touches them, on its own background thread, then hands the fresh list to
    /// whoever is looping over the result with `for try await`. ≈ Room's `Flow<List<T>>` or a
    /// Supabase subscription. The loop ends when the task running it is cancelled, which also
    /// stops the watching. `removeDuplicates` skips a delivery when a write changed nothing the
    /// list shows (for example, bytes of an item below the limit), so the panel is not redrawn
    /// for nothing. (`some AsyncSequence<...>` hides GRDB's own type: callers only see "a
    /// sequence of item lists that can fail", so the app never has to import GRDB.)
    // shortcut: a date range is worked out once, when the query starts, so a panel left open
    // across midnight keeps yesterday's "today" until the filter or the panel changes; restart
    // the query on a day change if anyone notices.
    public func observeItems(matching filter: ItemFilter = ItemFilter(), limit: Int)
        -> some AsyncSequence<[ClipboardItem], any Error>
    {
        let request = ClipboardItem.matching(filter, now: Date(), calendar: .current)
        return
            ValueObservation
            .tracking { db in try request.limit(limit).fetchAll(db) }
            .removeDuplicates()
            .values(in: pool)
    }

    /// Every pinboard in tab order, delivered now and again whenever one is added, renamed or
    /// deleted: the same kind of live query as `observeItems`, for the panel's tab row.
    public func observePinboards() -> some AsyncSequence<[Pinboard], any Error> {
        ValueObservation
            .tracking { db in try Pinboard.inOrder.fetchAll(db) }
            .removeDuplicates()
            .values(in: pool)
    }

    /// Every pinboard in tab order, once.
    public func pinboards() async throws -> [Pinboard] {
        try await pool.read { db in try Pinboard.inOrder.fetchAll(db) }
    }

    /// Adds a pinboard after the existing ones and returns it. The name is used as given;
    /// the panel trims it and refuses an empty one before calling this.
    public func createPinboard(named name: String) async throws -> Pinboard {
        try await pool.write { db in
            // The new tab goes last: one past the highest position so far (0 for the first).
            let last = try Pinboard.select(max(PinboardColumns.position), as: Int.self).fetchOne(db)
            let pinboard = try NewPinboard(name: name, position: (last ?? -1) + 1)
                .insertAndFetch(db, as: Pinboard.self)
            Log.store.info("created pinboard \(pinboard.id, privacy: .public)")
            return pinboard
        }
    }

    /// Gives a pinboard a new name. Nothing happens if it was deleted in the meantime.
    public func renamePinboard(id: Int64, to name: String) async throws {
        _ = try await pool.write { db in
            try Pinboard.filter(key: id).updateAll(db, [PinboardColumns.name.set(to: name)])
        }
    }

    /// Deletes a pinboard. Its items are not deleted: the foreign key on `clipboardItem` is
    /// declared `ON DELETE SET NULL` (see Migrations), so SQLite clears their `pinboardId` in
    /// the same statement and they are back in History at once.
    public func deletePinboard(id: Int64) async throws {
        _ = try await pool.write { db in
            let deleted = try Pinboard.deleteOne(db, key: id)
            Log.store.info("deleted pinboard \(id, privacy: .public): \(deleted, privacy: .public)")
        }
    }

    /// Puts an item on a pinboard. An item is on one pinboard at most, so this also takes it
    /// off whichever one it was on, and off History. Nothing happens if either was deleted.
    public func pin(itemId: Int64, to pinboardId: Int64) async throws {
        _ = try await pool.write { db in
            // The foreign key would refuse a missing pinboard with an error; checking first
            // turns a race with a delete into a quiet no-op, which is what the user would want.
            guard try Pinboard.exists(db, key: pinboardId) else { return }
            try ClipboardItem.filter(key: itemId)
                .updateAll(db, [ClipboardItemColumns.pinboardId.set(to: pinboardId)])
        }
    }

    /// Takes an item off its pinboard, back into History.
    public func unpin(itemId: Int64) async throws {
        _ = try await pool.write { db in
            try ClipboardItem.filter(key: itemId)
                .updateAll(db, [ClipboardItemColumns.pinboardId.set(to: nil)])
        }
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

    /// Adds what the Enricher worked out for an item: its thumbnail and/or footer detail. One
    /// transaction, so the live list sees both at once. A thumbnail replaces the item's old one
    /// (`upsert`); a nil part leaves that side alone. Nothing happens if the item was deleted in
    /// the meantime: the thumbnail's foreign key would refuse it, so it is checked first.
    public func setPreview(_ preview: CardPreview, for itemId: Int64) async throws {
        try await pool.write { db in
            guard try ClipboardItem.exists(db, key: itemId) else { return }
            if let detail = preview.detail {
                _ = try ClipboardItem.filter(key: itemId)
                    .updateAll(db, [ClipboardItemColumns.cardDetail.set(to: detail)])
            }
            try preview.thumbnail?.upsert(db)
        }
    }

    /// The item's thumbnail, or nil when none has been made (yet).
    public func thumbnail(for itemId: Int64) async throws -> CardThumbnail? {
        try await pool.read { db in try CardThumbnail.fetchOne(db, key: itemId) }
    }

    /// A file Quick Look can open for the item: the file itself for a file item, otherwise the
    /// item's bytes written to a temporary file named after it, so Quick Look sees the right
    /// type. Images get their best image type; anything else is written as plain text. Nil when
    /// the item has no data. The write happens off the main thread, like every read here.
    public func quickLookFile(for item: ClipboardItem) async throws -> URL? {
        let data = try await data(for: item.id)
        if item.kind == .file {
            return data.first { $0.type == ClipboardType.fileURL }.flatMap { URL(string: $0.text) }
        }
        // The first image type the source app offered that we know an extension for; Quick
        // Look picks its viewer from the extension, so a TIFF must not be called .png.
        let extensions = [
            "public.png": "png", "public.jpeg": "jpg", "public.tiff": "tiff", "public.heic": "heic",
            "com.compuserve.gif": "gif",
        ]
        let (type, ext) =
            data.lazy.compactMap { d in extensions[d.type].map { (d.type, $0) } }.first
            ?? (ClipboardType.plainText, "txt")
        guard let bytes = data.first(where: { $0.type == type })?.data else { return nil }
        // One file per item in the app's temporary folder, overwritten on each preview. macOS
        // empties that folder on its own, so nothing here has to clean up.
        let folder = URL.temporaryDirectory.appending(path: "QuickLook")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(item.id).\(ext)")
        try bytes.write(to: url, options: .atomic)
        return url
    }

    /// Up to this many matches are sorted best match first; more than this and they come
    /// newest first instead. SQLite scores every matching row one by one, about 1 µs each on
    /// an M-series Mac, so scoring 50,000 matches of a two-letter search over a big history
    /// would take 50 ms, past the speed limit; 5,000 takes about 6 ms. A search that broad is
    /// a prefix of a very common word, where the score says little anyway and newest first is
    /// what the user expects of a history.
    static let rankedMatchLimit = 5_000

    /// The items that match what the user typed, at most `limit` of them: best match first
    /// when the match is narrow enough to score (see `rankedMatchLimit`), newest first among
    /// equals and otherwise. Matches the card text, a title, text read out of an image, a
    /// link's page title and the source app's name, each word as a prefix ("qua" finds
    /// "quarterly"), and every word must match. Only items that `filter` allows (the tab,
    /// kind and date the panel is on) are searched, so the two narrow the list together.
    ///
    /// Returns `nil` when the text is not a search yet: fewer than two letters, or nothing
    /// searchable in it (only spaces or punctuation). The caller shows the full list then.
    /// Two letters is where the index's prefix tables begin; a single letter would match most
    /// of the history, which is the one slow case.
    public func search(_ query: String, matching filter: ItemFilter = ItemFilter(), limit: Int)
        async throws -> [ClipboardItem]?
    {
        // Full-text search has no `filter` equivalent: SQLite's `MATCH` takes a search pattern
        // in its own little language, with special words (OR, NOT) and symbols (quotes, *).
        // `FTS5Pattern` turns anything the user typed into a safe pattern, so "don't" or "c++"
        // or a stray quote can never break the query or be misread as an operator.
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
            let pattern = FTS5Pattern(matchingAllPrefixesIn: query)
        else { return nil }
        let filtered = ClipboardItem.matching(filter, now: Date(), calendar: .current)
        return try await pool.read { db in
            // Counting the matches first is cheap (the index answers it without scoring), and
            // it decides whether scoring all of them would fit in the speed limit.
            let matches = try clipboardItemSearchIndex.all().matching(pattern).fetchCount(db)
            // The index is joined to the item table (`joining(required:)` = INNER JOIN) with the
            // MATCH in the join condition, which is how SQLite wants a full-text query over a
            // separate content table. The `TableAlias` names the index's side of the join, so
            // the ordering can reach its `rank` column: FTS5's score, lowest first = best match.
            // `order` here replaces the newest-first order `matching` set; its `WHERE` clauses
            // stay, so the search only sees the items the panel's tab and filter allow.
            let index = TableAlias()
            let byScore: [any SQLOrderingTerm] = matches <= Self.rankedMatchLimit ? [index[Column.rank]] : []
            return
                try filtered
                .joining(required: ClipboardItem.searchIndex.aliased(index).matching(pattern))
                .order(byScore + [ClipboardItemColumns.copiedAt.desc, ClipboardItemColumns.id.desc])
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Deletes an item, its data rows (SQLite does that by cascade) and its files on disk.
    public func delete(id: Int64) async throws {
        try await delete(ids: [id])
    }

    /// Deletes several items at once: one transaction for the rows, then their files. The
    /// live list drops them all in one delivery, so the panel never shows a half-deleted
    /// selection.
    public func delete(ids: [Int64]) async throws {
        // Rows first, files second: a crash in between leaves an unreferenced file for the sweep,
        // never a row pointing at a missing file.
        let fileNames = try await pool.write { db in
            let names = try ClipboardItemDataRow.fileNames(in: ClipboardItemDataRow.ofItems(ids))
                .fetchAll(db)
            let count = try ClipboardItem.deleteAll(db, keys: ids)
            Log.store.info("deleted \(count) items")
            return names
        }
        try files.delete(fileNames)
    }

    /// Gives an item your own name, shown on its card instead of the first line and found by
    /// search (the index's triggers pick the column up). Nil, or a blank name, clears it so
    /// the first line is back.
    public func rename(id: Int64, to title: String?) async throws {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = title.flatMap { $0.isEmpty ? nil : $0 }
        _ = try await pool.write { db in
            try ClipboardItem.filter(key: id).updateAll(db, [ClipboardItemColumns.title.set(to: stored)])
        }
    }

    /// Makes a second, separate item with the same content, title and pinboard, copied now,
    /// so it sits at the top. The two share a fingerprint: copying that content again moves
    /// whichever is newest to the top, and the other stays where it is. Large data files are
    /// copied too, so deleting one item never takes the other's bytes away. Returns the new
    /// item, or nil if the original was deleted meanwhile.
    @discardableResult
    public func duplicate(id: Int64) async throws -> ClipboardItem? {
        let files = self.files
        // The files are copied before the transaction, like a save writes them first: a row
        // never points at a file that is not there yet. On failure they are removed again.
        let rows = try await pool.read { db in try ClipboardItemDataRow.ofItem(id).fetchAll(db) }
        let copiedFileNames: [String?] = try rows.map { row in
            try row.largeDataFileName.map { try files.write(try files.read($0)) }
        }
        do {
            return try await pool.write { db in
                guard let original = try ClipboardItem.fetchOne(db, key: id) else { return nil }
                let now = Date()
                let copy = try NewClipboardItem(
                    kind: original.kind, title: original.title, cardText: original.cardText,
                    cardDetail: original.cardDetail, sourceAppBundleId: original.sourceAppBundleId,
                    sourceAppName: original.sourceAppName, createdAt: now, copiedAt: now,
                    contentFingerprint: original.contentFingerprint, imageText: original.imageText,
                    linkPageTitle: original.linkPageTitle, pinboardId: original.pinboardId
                ).insertAndFetch(db, as: ClipboardItem.self)
                for (row, fileName) in zip(rows, copiedFileNames) {
                    var row = row
                    row.id = nil
                    row.clipboardItemId = copy.id
                    row.largeDataFileName = fileName
                    try row.insert(db)
                }
                // The thumbnail is keyed by item id, so the copy gets its own row of it.
                if var thumbnail = try CardThumbnail.fetchOne(db, key: id) {
                    thumbnail.clipboardItemId = copy.id
                    try thumbnail.insert(db)
                }
                Log.store.info("duplicated item \(id, privacy: .public) as \(copy.id, privacy: .public)")
                return copy
            }
        } catch {
            try? files.delete(copiedFileNames.compactMap { $0 })
            throw error
        }
    }

    /// Deletes every item that is not on a pinboard, with its data rows, thumbnail (both by
    /// cascade) and large files, then rebuilds the database file so the space goes back to the
    /// disk. Pinned items are untouched. The rows go in one transaction, so a crash in the
    /// middle erases nothing; the files go after it commits (a crash there leaves files for
    /// the launch sweep). Rebuilding (`VACUUM`, here GRDB's `vacuum`) copies the live rows
    /// into a fresh file, so it runs last and can take a moment on a big history; the caller
    /// awaits all of it off the main thread.
    public func eraseHistory() async throws {
        let fileNames = try await pool.write { db in
            let names = try ClipboardItemDataRow.fileNames(in: ClipboardItemDataRow.ofUnpinnedItems)
                .fetchAll(db)
            let count = try ClipboardItem.filter(ClipboardItemColumns.pinboardId == nil).deleteAll(db)
            Log.store.info("erased \(count) items")
            return names
        }
        try files.delete(fileNames)
        try await pool.vacuum()
        // The database runs in WAL mode (writes go to a side file first, see the top of this
        // file), so the rebuilt pages sit in that side file until a checkpoint copies them into
        // the main file. Doing it now, with `truncate`, is what makes the files on disk small
        // right away instead of at some later automatic checkpoint.
        _ = try await pool.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
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

        /// Replaces everything in this store (items and pinboards) with `count` fake items, all
        /// small, with a mix of kinds and apps and times spread over the past, newest first by
        /// id. One transaction, so 100,000 items take a second or two instead of minutes of
        /// single saves.
        public func seed(count: Int) async throws {
            try await pool.write { db in
                try ClipboardItem.deleteAll(db)
                try Pinboard.deleteAll(db)
                let now = Date()
                // Real bundle ids of apps every Mac has, so the cards get real icons and colours.
                let apps = [
                    ("Safari", "com.apple.Safari"), ("TextEdit", "com.apple.TextEdit"),
                    ("Terminal", "com.apple.Terminal"), ("Notes", "com.apple.Notes"),
                    ("Finder", "com.apple.finder"), ("Mail", "com.apple.mail"),
                ]
                for i in 0..<count {
                    let (app, bundleId) = apps[i % apps.count]
                    // Half the items are text; the rest cycle through link, file, colour and
                    // image, so a seeded panel shows every kind of card. The image is a real
                    // one-pixel PNG, so anything that decodes it later works on seeded data too.
                    // The footer details are made up to look like real ones.
                    let (kind, text, detail, type, data): (ItemKind, String, String, String, Data) =
                        switch i % 8 {
                        case 1:
                            (
                                .link, "https://example.com/pages/\(i)", "example.com", ClipboardType.url,
                                Data()
                            )
                        case 3:
                            // A real file URL (to a file that does not exist), so the code that
                            // reads file URLs sees the same shape as from Finder.
                            (
                                .file, "report-\(i).pdf", "\(i % 900 + 24) KB", ClipboardType.fileURL,
                                Data("file:///tmp/report-\(i).pdf".utf8)
                            )
                        case 5:
                            (.color, "", "#2B59D6", ClipboardType.color, Data())
                        case 7:
                            (.image, "", "1 × 1", "public.png", Self.onePixelPNG)
                        default:
                            (
                                .text, "Sample item \(i): meeting moved to 3 pm Thursday.",
                                "\(45 + String(i).count) characters", ClipboardType.plainText, Data()
                            )
                        }
                    // Items 97 seconds apart, so a 100,000-item history spans about four months.
                    let copiedAt = now.addingTimeInterval(-97 * Double(i))
                    let item = try NewClipboardItem(
                        kind: kind, cardText: text, cardDetail: detail, sourceAppBundleId: bundleId,
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
