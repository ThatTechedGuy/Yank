import Foundation
import GRDB

// A read-only window onto the Store's database and files for the Developer window, in debug
// builds only. It opens its own connection to the same SQLite file instead of going through the
// Store, for two reasons: its queries never queue behind the app's own reads, and they never show
// up in the SQL trace the Store writes to the log (see Store.init), so watching the app does not
// change what is being watched. SQLite's WAL mode lets this extra reader see the last committed
// state while the Store keeps writing. ≈ opening the database in DB Browser for SQLite while the
// app runs, but from inside the app.
//
// It is an `actor`: a class whose methods run one at a time on their own background thread, so
// the file-size counting and the queries never touch the main thread, and callers simply `await`
// the results. ≈ an object whose every method is `async` and internally serialised.
//
// Only the Store and this type may use GRDB, so the Developer window gets plain values back:
// `Snapshot` and `ItemRow` below.
#if DEBUG
    /// Read-only facts about the database and its files, for the Developer window.
    public actor StoreInspector {
        /// Everything the Developer window shows about the database, read in one go.
        public struct Snapshot: Sendable {
            /// How many items are saved, and how many of each kind.
            public let itemCount: Int
            public let countsByKind: [ItemKind: Int]
            /// Rows in the full-text search index. Equals `itemCount` unless the index is stale.
            public let searchIndexRowCount: Int
            /// The newest items, as the Database tab lists them.
            public let newestItems: [ItemRow]
            /// Size of yank.sqlite plus its write-ahead log (the -wal file), in bytes.
            public let databaseBytes: Int
            /// Size of every file in the LargeData folder, in bytes.
            public let largeDataBytes: Int
            /// SQLite's change counter for this database (see `PRAGMA data_version`), so the
            /// next call can skip the work when nothing was written in between.
            public let dataVersion: Int
        }

        /// One item as the Database tab lists it: the card's facts plus how many bytes of
        /// clipboard data it carries, in the row and in large-data files together.
        public struct ItemRow: Sendable, Identifiable, Hashable {
            public let id: Int64
            public let kind: ItemKind
            public let cardText: String
            public let sourceAppName: String?
            public let copiedAt: Date
            public let dataBytes: Int
        }

        private let queue: DatabaseQueue
        private let folder: URL

        /// Opens the database in `folder` read-only. The Store must have created it already.
        public init(folder: URL) throws {
            self.folder = folder
            // `readonly` opens the file with SQLite's read-only flag: this connection cannot
            // write even by mistake. No trace is installed, so its statements stay out of the
            // "sql" log. A `DatabaseQueue` is one connection; one reader needs no pool.
            var configuration = Configuration()
            configuration.readonly = true
            queue = try DatabaseQueue(
                path: folder.appending(path: "yank.sqlite").path, configuration: configuration)
        }

        /// Reads a fresh snapshot, or returns nil when nothing has been written since the
        /// snapshot whose `dataVersion` is passed in, so a caller polling once a second does no
        /// real work while the database is quiet. Pass nil to always read.
        public func snapshot(ifChangedSince version: Int?, newestLimit: Int) throws -> Snapshot? {
            try queue.read { db in
                // `PRAGMA data_version` is SQLite's own "did another connection commit?" counter:
                // it changes whenever a different connection has written to the file. This is a
                // question the query builder has no way to ask, so it is the one raw SQL here.
                let dataVersion = try Int.fetchOne(db, sql: "PRAGMA data_version") ?? 0
                if dataVersion == version { return nil }
                // `SELECT kind, COUNT(id) FROM clipboardItem GROUP BY kind`, read as plain rows.
                let countRows = try Row.fetchAll(
                    db,
                    ClipboardItem
                        .select(ClipboardItemColumns.kind, count(ClipboardItemColumns.id))
                        .group(ClipboardItemColumns.kind))
                var countsByKind: [ItemKind: Int] = [:]
                for row in countRows {
                    if let kind = ItemKind(rawValue: row[0]) { countsByKind[kind] = row[1] }
                }
                let newest = try ClipboardItem.newestFirst.limit(newestLimit).fetchAll(db)
                return Snapshot(
                    itemCount: countsByKind.values.reduce(0, +),
                    countsByKind: countsByKind,
                    searchIndexRowCount: try clipboardItemSearchIndex.fetchCount(db),
                    newestItems: try newest.map { item in
                        ItemRow(
                            id: item.id, kind: item.kind, cardText: item.cardText,
                            sourceAppName: item.sourceAppName, copiedAt: item.copiedAt,
                            dataBytes: try dataBytes(of: item.id, db))
                    },
                    databaseBytes: fileSize("yank.sqlite") + fileSize("yank.sqlite-wal"),
                    largeDataBytes: folderSize("LargeData"),
                    dataVersion: dataVersion)
            }
        }

        /// How many bytes of clipboard data one item has: the row data, measured by SQLite with
        /// `length()` so the bytes are never loaded, plus the size of each large-data file.
        nonisolated private func dataBytes(of itemId: Int64, _ db: Database) throws -> Int {
            let rows = ClipboardItemDataRow.ofItem(itemId)
            let inline =
                try rows.select(sum(length(ClipboardItemDataRow.Columns.data)), as: Int.self)
                .fetchOne(db) ?? 0
            let files = try ClipboardItemDataRow.fileNames(in: rows).fetchAll(db)
            return inline + files.reduce(0) { $0 + fileSize("LargeData/\($1)") }
        }

        /// Size in bytes of one file inside the data folder; 0 if it does not exist.
        nonisolated private func fileSize(_ name: String) -> Int {
            let values = try? folder.appending(path: name).resourceValues(forKeys: [.fileSizeKey])
            return values?.fileSize ?? 0
        }

        /// Total size in bytes of the files directly inside one folder of the data folder.
        nonisolated private func folderSize(_ name: String) -> Int {
            let url = folder.appending(path: name)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            return names.reduce(0) { $0 + fileSize("\(name)/\($1)") }
        }
    }
#endif
