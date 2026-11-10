import Foundation
import GRDB

// The one place that touches the disk: every read and write of the database and of the large data
// files goes through the Store, with GRDB's record API (see Records.swift), never hand-written SQL.
/// Saves, lists and searches clipboard items. One instance per app.
public final class Store: Sendable {
    private let pool: DatabasePool
    private let files: LargeDataFiles
    /// Where Quick Look, Share and Open With get their temporary copies of an item's bytes. One
    /// folder per Store folder, so clearing it can never touch another Store's copies.
    private let quickLookFolder: URL

    /// Opens (or creates) the database in `folder`, runs migrations and removes orphan files.
    /// Runs on the caller's thread; the app calls it on the main thread at launch.
    public init(folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var configuration = Configuration()
        #if DEBUG
            // The SQL is logged as prepared, with `?` where the values go, so clipboard contents
            // never reach the log; that is why it can be public. SQLite measures the duration with
            // a millisecond clock, so "0 ms" means under one.
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
        quickLookFolder = URL.temporaryDirectory.appending(path: "QuickLook/\(folder.lastPathComponent)")
        try Migrations.migrator.migrate(pool)
        // Data files no row points at are left by a crash mid-save or mid-delete (see LargeDataFiles).
        let (count, fileNames) = try pool.read { db in
            (
                try ClipboardItem.fetchCount(db),
                try ClipboardItemDataRow.fileNames(in: ClipboardItemDataRow.all()).fetchSet(db)
            )
        }
        try files.sweep(keeping: fileNames)
        Log.store.info("opened store at \(folder.path, privacy: .public) with \(count) items")
    }

    // Inside the sandbox container, so a debug build, with its own bundle id, gets a separate folder.
    /// Where the real app keeps its data.
    public static var defaultFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Yank")
    }

    /// Saves a copy as a new item, or moves the existing item with the same content to the top.
    /// Returns the saved item either way.
    @discardableResult
    public func save(_ copy: CapturedCopy) async throws -> ClipboardItem {
        let (kind, fingerprint, cardText, cardDetail, searchText) = Self.describe(copy.data)
        // Large data goes to disk before the transaction, so a row never points at a file that
        // isn't fully there yet. `write(newFiles:)` removes the files if the transaction fails.
        let fileNames = try writeLargeData(of: copy.data)
        return try await write(newFiles: fileNames) { db in
            // A repeat copy reuses the newest item with the same content, which keeps its id,
            // title and pinboard. Its old files are deleted only after this transaction commits.
            let existing =
                try ClipboardItem
                .filter(ClipboardItemColumns.contentFingerprint == fingerprint)
                .order(ClipboardItemColumns.copiedAt.desc).fetchOne(db)
            let item: ClipboardItem
            var oldFileNames: [String] = []
            if var existing {
                existing.copiedAt = copy.copiedAt
                existing.cardText = cardText
                // A detail the save cannot compute (an image's size) is left as the Enricher set
                // it last time: the bytes are the same, so it still holds.
                existing.cardDetail = cardDetail ?? existing.cardDetail
                existing.sourceAppBundleId = copy.sourceApp?.bundleId
                existing.sourceAppName = copy.sourceApp?.name
                try existing.update(db)
                _ = try ClipboardItem.filter(key: existing.id)
                    .updateAll(db, [ClipboardItemColumns.searchText.set(to: searchText)])
                item = existing
                let oldRows = ClipboardItemDataRow.ofItem(item.id)
                oldFileNames = try ClipboardItemDataRow.fileNames(in: oldRows).fetchAll(db)
                try oldRows.deleteAll(db)
            } else {
                item = try NewClipboardItem(
                    kind: kind, cardText: cardText, searchText: searchText, cardDetail: cardDetail,
                    sourceAppBundleId: copy.sourceApp?.bundleId,
                    sourceAppName: copy.sourceApp?.name, createdAt: copy.copiedAt,
                    copiedAt: copy.copiedAt, contentFingerprint: fingerprint
                ).insertAndFetch(db, as: ClipboardItem.self)
            }
            try Self.insertDataRows(db, of: item.id, data: copy.data, fileNames: fileNames)
            let verb = existing == nil ? "saved" : "moved to top"
            Log.store.info(
                "\(verb, privacy: .public) item \(item.id, privacy: .public) kind \(kind.rawValue, privacy: .public)"
            )
            return (item, oldFileNames)
        }
    }

    /// Gives an item new bytes in place: the editor's "Replace Original". It keeps its id,
    /// `copiedAt`, title, source app and pinboard; the rest is worked out afresh, as in a save.
    /// The thumbnail, image text and link page title are dropped because they described the old
    /// bytes; the caller runs the Enricher again. Returns nil if the item was deleted meanwhile.
    public func replaceData(for id: Int64, with data: [ClipboardItemData]) async throws -> ClipboardItem? {
        let (kind, fingerprint, cardText, cardDetail, searchText) = Self.describe(data)
        let fileNames = try writeLargeData(of: data)
        return try await write(newFiles: fileNames) { db -> (ClipboardItem?, [String]) in
            // The item is gone, so the files just written for it belong to nobody.
            guard var item = try ClipboardItem.fetchOne(db, key: id) else {
                return (nil, fileNames.compactMap { $0 })
            }
            item.kind = kind
            item.cardText = cardText
            item.cardDetail = cardDetail
            item.contentFingerprint = fingerprint
            item.imageText = nil
            item.linkPageTitle = nil
            try item.update(db)
            _ = try ClipboardItem.filter(key: id)
                .updateAll(db, [ClipboardItemColumns.searchText.set(to: searchText)])
            let oldRows = ClipboardItemDataRow.ofItem(id)
            let oldFileNames = try ClipboardItemDataRow.fileNames(in: oldRows).fetchAll(db)
            try oldRows.deleteAll(db)
            try Self.insertDataRows(db, of: id, data: data, fileNames: fileNames)
            _ = try CardThumbnail.deleteOne(db, key: id)
            Log.store.info(
                "replaced data of item \(id, privacy: .public) kind \(kind.rawValue, privacy: .public)")
            return (item, oldFileNames)
        }
    }

    /// What a save works out from a copy's bytes. None of it needs the database, so it is
    /// computed before the write block and the one writer is busy only for the actual SQL.
    private static func describe(_ data: [ClipboardItemData]) -> (
        kind: ItemKind, fingerprint: String, cardText: String, cardDetail: String?, searchText: String
    ) {
        let kind = ItemKind.detect(data)
        return (
            kind, DuplicateKey.make(kind: kind, data: data), CardText.make(kind: kind, data: data),
            CardDetail.make(kind: kind, data: data), CardText.searchText(kind: kind, data: data)
        )
    }

    /// Writes each piece of data that is too big for its row to a file, and returns one file name
    /// per piece (nil for the small ones). Called before a transaction, see `save`.
    private func writeLargeData(of data: [ClipboardItemData]) throws -> [String?] {
        try data.map { item in
            item.data.count <= LargeDataFiles.inlineLimit ? nil : try files.write(item.data)
        }
    }

    /// One write transaction whose rows point at large files written just before it. The block
    /// returns its result and the files to delete once it has committed: those whose rows it
    /// dropped, or the new ones when the item turned out to be gone. If the block throws, the new
    /// files go instead. Deleting is best effort: the launch sweep catches leftovers.
    private func write<T: Sendable>(
        newFiles: [String?], _ updates: @Sendable (Database) throws -> (T, [String])
    ) async throws -> T {
        let (result, unusedFiles): (T, [String])
        do {
            (result, unusedFiles) = try await pool.write(updates)
        } catch {
            try? files.delete(newFiles.compactMap { $0 })
            throw error
        }
        try? files.delete(unusedFiles)
        return result
    }

    /// One data row per clipboard type, in the source app's order (`position`). Large data is
    /// already in the file `writeLargeData` made, and the row keeps only its name.
    private static func insertDataRows(
        _ db: Database, of itemId: Int64, data: [ClipboardItemData], fileNames: [String?]
    ) throws {
        for (position, item) in data.enumerated() {
            let fileName = fileNames[position]
            try ClipboardItemDataRow(
                clipboardItemId: itemId, pasteboardItemIndex: item.pasteboardItemIndex,
                position: position, type: item.type, data: fileName == nil ? item.data : nil,
                largeDataFileName: fileName
            ).insert(db)
        }
    }

    /// Moves items to the top of the history, as a paste from the panel does, keeping their
    /// order: the first id ends up newest. Each gets a `copiedAt` one millisecond older than the
    /// one before, because the column keeps milliseconds and equal times fall back to id order.
    public func moveToTop(ids: [Int64]) async throws {
        let now = Date()
        try await pool.write { db in
            for (offset, id) in ids.enumerated() {
                _ = try ClipboardItem.filter(key: id)
                    .updateAll(db, [ClipboardItemColumns.copiedAt.set(to: now - Double(offset) / 1000)])
            }
        }
    }

    /// The newest `limit` items, once. The panel uses the live form, `observeItems`.
    public func items(limit: Int) async throws -> [ClipboardItem] {
        try await pool.read { db in try ClipboardItem.newestFirst.limit(limit).fetchAll(db) }
    }

    /// The newest `limit` items that match `filter` (the default is all of History), delivered
    /// now and again every time they change. `removeDuplicates` skips a delivery when a write
    /// changed nothing the list shows. The opaque return type keeps GRDB out of the app.
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

    /// Every pinboard in tab order, delivered now and again whenever one changes.
    public func observePinboards() -> some AsyncSequence<[Pinboard], any Error> {
        ValueObservation
            .tracking { db in try Pinboard.inOrder.fetchAll(db) }
            .removeDuplicates()
            .values(in: pool)
    }

    /// Every pinboard in tab order, once. Only the tests read it this way.
    func pinboards() async throws -> [Pinboard] {
        try await pool.read { db in try Pinboard.inOrder.fetchAll(db) }
    }

    /// Adds a pinboard after the existing ones and returns it. The name is used as given;
    /// the panel trims it and refuses an empty one before calling this.
    public func createPinboard(named name: String) async throws -> Pinboard {
        try await pool.write { db in
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
    /// `ON DELETE SET NULL` (see Migrations), so they are back in History at once.
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
            // A missing pinboard would fail the foreign key; this makes a race with a delete a no-op.
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

    /// How many items are saved, once. The tests check it; the menu watches `observeCount`.
    public func count() async throws -> Int {
        try await pool.read { db in try ClipboardItem.fetchCount(db) }
    }

    /// How many items are saved, delivered now and again whenever the number changes, for the
    /// menu. A write that leaves the count as it was (a repeat copy) delivers nothing.
    public func observeCount() -> some AsyncSequence<Int, any Error> {
        ValueObservation
            .tracking { db in try ClipboardItem.fetchCount(db) }
            .removeDuplicates()
            .values(in: pool)
    }

    /// All clipboard data of one item, in the source app's order, with large data read from disk.
    public func data(for itemId: Int64) async throws -> [ClipboardItemData] {
        let files = self.files
        return try await pool.read { db in
            try ClipboardItemDataRow.ofItem(itemId).fetchAll(db).map { row in
                // Exactly one of the two is set, so the `?? Data()` fallback never runs.
                let data = try row.largeDataFileName.map(files.read) ?? row.data ?? Data()
                return ClipboardItemData(
                    pasteboardItemIndex: row.pasteboardItemIndex, type: row.type, data: data)
            }
        }
    }

    /// Saves what the Enricher worked out for an item, in one transaction so the live list sees
    /// all of it at once; a nil part is left alone. Nothing happens if the item was deleted in
    /// the meantime: the thumbnail's foreign key would refuse it, so it is checked first.
    public func setPreview(_ preview: CardPreview, for itemId: Int64) async throws {
        try await pool.write { db in
            guard try ClipboardItem.exists(db, key: itemId) else { return }
            let changes = [
                preview.detail.map { ClipboardItemColumns.cardDetail.set(to: $0) },
                preview.imageText.map { ClipboardItemColumns.imageText.set(to: $0) },
                preview.linkPageTitle.map { ClipboardItemColumns.linkPageTitle.set(to: $0) },
            ].compactMap { $0 }
            if !changes.isEmpty {
                _ = try ClipboardItem.filter(key: itemId).updateAll(db, changes)
            }
            try preview.thumbnail?.upsert(db)
        }
    }

    /// The item's thumbnail, or nil when none has been made (yet).
    public func thumbnail(for itemId: Int64) async throws -> CardThumbnail? {
        try await pool.read { db in try CardThumbnail.fetchOne(db, key: itemId) }
    }

    /// A file Quick Look can open for the item: the file itself for a file item, otherwise the
    /// item's image or plain text written to a temporary file. Nil when it has neither.
    public func quickLookFile(for item: ClipboardItem) async throws -> URL? {
        let data = try await data(for: item.id)
        if item.kind == .file {
            return data.first { $0.type == ClipboardType.fileURL }.flatMap { URL(string: $0.text) }
        }
        // Quick Look picks its viewer from the extension, so a TIFF must not be called .png.
        let extensions = [
            "public.png": "png", "public.jpeg": "jpg", "public.tiff": "tiff", "public.heic": "heic",
            "com.compuserve.gif": "gif",
        ]
        let image = data.firstImage
        let ext = image.flatMap { extensions[$0.type] }
        let chosen = ext == nil ? data.first { $0.type == ClipboardType.plainText } : image
        guard let bytes = chosen?.data else { return nil }
        // One file per item, overwritten on each preview; deleting items clears the folder.
        try FileManager.default.createDirectory(at: quickLookFolder, withIntermediateDirectories: true)
        let url = quickLookFolder.appending(path: "\(item.id).\(ext ?? "txt")")
        try bytes.write(to: url, options: .atomic)
        return url
    }

    /// Removes every temporary copy, so deleted content does not linger in the temporary folder
    /// until macOS gets round to it. The copies of other items are written again when needed.
    private func removeQuickLookCopies() {
        try? FileManager.default.removeItem(at: quickLookFolder)
    }

    /// Up to this many matches are sorted best match first; more than this and they come newest
    /// first instead. SQLite scores every matching row, about 1 µs each on an M-series Mac, so
    /// the 50,000 matches of a two-letter search over a big history would take 50 ms; 5,000 takes
    /// about 6 ms. A search that broad is a prefix of a very common word, where the score says
    /// little anyway.
    static let rankedMatchLimit = 5_000

    /// The items `filter` allows that match what the user typed, at most `limit` of them: best
    /// match first when few enough to score (see `rankedMatchLimit`), newest first among equals
    /// and otherwise. Every word must match, as a prefix ("qua" finds "quarterly"), in the item's
    /// text, title, image text, link page title or source app name.
    ///
    /// Returns `nil` when the text is not a search yet: fewer than two letters, or nothing
    /// searchable in it (only spaces or punctuation). Two letters is where the index's prefix
    /// tables begin; a single letter would match most of the history, the one slow case.
    public func search(_ query: String, matching filter: ItemFilter = ItemFilter(), limit: Int)
        async throws -> [ClipboardItem]?
    {
        // `FTS5Pattern` makes anything typed safe: "don't", "c++" or a stray quote can never
        // break the query or be misread as an operator.
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
            let pattern = FTS5Pattern(matchingAllPrefixesIn: query)
        else { return nil }
        let filtered = ClipboardItem.matching(filter, now: Date(), calendar: .current)
        return try await pool.read { db in
            // Counting first is cheap (the index answers without scoring) and decides whether to rank.
            let matches = try clipboardItemSearchIndex.all().matching(pattern).fetchCount(db)
            // The alias lets the ordering reach the index's `rank` column: FTS5's score, lowest
            // is best. `order` replaces the newest-first order `matching` set; its filters stay.
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

    /// Deletes several items in one transaction, then their files. The live list drops them all
    /// in one delivery, so the panel never shows a half-deleted selection.
    public func delete(ids: [Int64]) async throws {
        try await deleteItems(in: ClipboardItem.filter(keys: ids))
    }

    /// Gives an item your own name, shown on its card instead of the first line and found by
    /// search. Nil, or a blank name, clears it so the first line is back.
    public func rename(id: Int64, to title: String?) async throws {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = title.flatMap { $0.isEmpty ? nil : $0 }
        _ = try await pool.write { db in
            try ClipboardItem.filter(key: id).updateAll(db, [ClipboardItemColumns.title.set(to: stored)])
        }
    }

    /// Makes a second, separate item with the same content, title and pinboard, copied now. The
    /// two share a fingerprint: copying that content again moves whichever is newest to the top.
    /// Large data files are copied too, so deleting one item never takes the other's bytes away.
    /// Returns the new item, or nil if the original was deleted meanwhile.
    @discardableResult
    public func duplicate(id: Int64) async throws -> ClipboardItem? {
        let files = self.files
        // Files are copied before the transaction, as in `save`: a row never points at a missing file.
        let rows = try await pool.read { db in try ClipboardItemDataRow.ofItem(id).fetchAll(db) }
        let copiedFileNames: [String?] = try rows.map { row in
            try row.largeDataFileName.map { try files.write(try files.read($0)) }
        }
        return try await write(newFiles: copiedFileNames) { db -> (ClipboardItem?, [String]) in
            // The original is gone, so the copies of its files belong to nobody.
            guard let original = try ClipboardItem.fetchOne(db, key: id) else {
                return (nil, copiedFileNames.compactMap { $0 })
            }
            let now = Date()
            let searchText =
                try ClipboardItem.filter(key: id)
                .select(ClipboardItemColumns.searchText, as: String.self).fetchOne(db)
            let copy = try NewClipboardItem(
                kind: original.kind, title: original.title, cardText: original.cardText,
                searchText: searchText ?? original.cardText,
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
            return (copy, [])
        }
    }

    /// Deletes every item that is not on a pinboard, with its data rows, thumbnail (both by
    /// cascade) and large files, then rebuilds the database file so the space goes back to the
    /// disk. The rebuild copies the live rows into a fresh file, so it runs last and can take a
    /// moment on a big history.
    public func eraseHistory() async throws {
        try await deleteItems(in: ClipboardItem.filter(ClipboardItemColumns.pinboardId == nil))
        try await pool.vacuum()
        // In WAL mode the rebuilt pages sit in the -wal file until a checkpoint copies them into
        // the main file. Truncating now makes the files on disk small right away.
        _ = try await pool.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
    }

    /// Deletes every item not on a pinboard that was last copied before `cutoff`: the "Keep
    /// history" setting. No rebuild afterwards: it can take a while, and SQLite reuses the space.
    public func deleteUnpinned(copiedBefore cutoff: Date) async throws {
        try await deleteItems(
            in: ClipboardItem.filter(ClipboardItemColumns.pinboardId == nil)
                .filter(ClipboardItemColumns.copiedAt < cutoff))
    }

    /// One transaction for the rows, then the files: a crash between the two leaves files for
    /// the launch sweep, never a row pointing at a missing file. Takes a request, not a list of
    /// ids, so it can remove any number of items in one statement.
    private func deleteItems(in items: QueryInterfaceRequest<ClipboardItem>) async throws {
        let fileNames = try await pool.write { db in
            let names = try ClipboardItemDataRow.fileNames(in: ClipboardItemDataRow.ofItems(in: items))
                .fetchAll(db)
            let count = try items.deleteAll(db)
            Log.store.info("deleted \(count) items")
            return names
        }
        removeQuickLookCopies()
        try? files.delete(fileNames)
    }
}

// Fake history for trying the panel with thousands of items. It lives in this file because it
// needs the Store's private database handle: thousands of rows have to go in as one transaction.
#if DEBUG
    extension Store {
        /// Where the fake history lives: a folder next to the real one, so the two never mix.
        public static var seedFolder: URL {
            URL.applicationSupportDirectory.appending(path: "Yank-seed")
        }

        /// Replaces everything in this store (items and pinboards) with `count` small fake items
        /// of mixed kinds and apps, spread over the past. One transaction, so 100,000 items take
        /// a second or two instead of minutes of single saves.
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
                    let (kind, text, detail, type, data): (ItemKind, String, String, String, Data) =
                        switch i % 8 {
                        case 1:
                            (
                                .link, "https://example.com/pages/\(i)", "example.com", ClipboardType.url,
                                Data()
                            )
                        case 3:
                            // A file URL (to no real file) in the same shape Finder gives.
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
                        kind: kind, cardText: text, searchText: text, cardDetail: detail,
                        sourceAppBundleId: bundleId,
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

        /// A valid 1 × 1 PNG (one blue pixel), so anything that decodes a seeded image works.
        private static let onePixelPNG = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44,
            0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F,
            0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xD0,
            0x8E, 0xBC, 0xF6, 0x1F, 0x00, 0x04, 0x67, 0x02, 0x5A, 0xFC, 0x60, 0x66, 0xFC, 0x00, 0x00,
            0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
        ])
    }
#endif
