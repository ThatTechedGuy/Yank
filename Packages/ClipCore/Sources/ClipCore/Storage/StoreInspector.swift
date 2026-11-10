import Foundation
import GRDB

// Opens its own read-only connection to the Store's SQLite file instead of going through the
// Store, so its queries never queue behind the app's own reads and never show up in the SQL trace
// the Store logs (see Store.init).
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
            /// Size of yank.sqlite plus its write-ahead log (the -wal file), in bytes.
            public let databaseBytes: Int
            /// Size of every file in the LargeData folder, in bytes.
            public let largeDataBytes: Int
            /// SQLite's change counter for this database (see `PRAGMA data_version`), so the
            /// next call can skip the work when nothing was written in between.
            public let dataVersion: Int
        }

        /// One table of the database, as the Database tab's table picker lists it.
        public struct TableInfo: Sendable, Identifiable, Hashable {
            public var id: String { name }
            public let name: String
            public let rowCount: Int
            /// Columns in the table's own order.
            public let columns: [TableColumnInfo]
        }

        /// One column: its name and declared type ("TEXT", "BLOB", "" for an FTS5 column).
        public struct TableColumnInfo: Sendable, Identifiable, Hashable {
            public var id: String { name }
            public let name: String
            public let type: String
        }

        /// Every table in the file, read in one go, so the Database tab can offer them all and
        /// notice when a count changed.
        public struct TableList: Sendable {
            public let tables: [TableInfo]
            /// See `Snapshot.dataVersion`.
            public let dataVersion: Int
        }

        /// One cell of one row, as a plain value the Database tab can draw. A blob comes back as
        /// its size plus a preview (the whole image only up to `previewLimit`), so a page of rows
        /// stays small.
        public enum CellValue: Sendable, Hashable {
            case null
            case integer(Int64)
            case real(Double)
            case text(String)
            case blob(byteCount: Int, preview: BlobPreview?)
        }

        /// What a blob looks like, when that can be told from its bytes: readable text, or an
        /// image small enough to draw in a cell.
        public enum BlobPreview: Sendable, Hashable {
            case text(String)
            case image(Data)
        }

        /// One page of rows from one table. `rows[r][c]` is the cell for `columns[c]`.
        public struct Page: Sendable {
            public let rows: [[CellValue]]
        }

        /// Blobs longer than this (in bytes) are not sniffed for a preview at all.
        private static let previewLimit = 512 * 1024
        /// How many characters of a text blob the preview keeps.
        private static let previewTextLength = 200

        private let queue: DatabaseQueue
        private let folder: URL

        /// Opens the database in `folder` read-only. The Store must have created it already.
        public init(folder: URL) throws {
            self.folder = folder
            var configuration = Configuration()
            configuration.readonly = true
            queue = try DatabaseQueue(
                path: folder.appending(path: "yank.sqlite").path, configuration: configuration)
        }

        /// Reads a fresh snapshot, or returns nil when nothing has been written since the
        /// snapshot whose `dataVersion` is passed in, so a caller polling once a second does no
        /// real work while the database is quiet. Pass nil to always read.
        public func snapshot(ifChangedSince version: Int?) throws -> Snapshot? {
            try queue.read { db in
                guard let dataVersion = try dataVersion(db, ifChangedSince: version) else {
                    return nil
                }
                let countRows = try Row.fetchAll(
                    db,
                    ClipboardItem
                        .select(ClipboardItemColumns.kind, count(ClipboardItemColumns.id))
                        .group(ClipboardItemColumns.kind))
                var countsByKind: [ItemKind: Int] = [:]
                for row in countRows {
                    if let kind = ItemKind(rawValue: row[0]) { countsByKind[kind] = row[1] }
                }
                return Snapshot(
                    itemCount: countsByKind.values.reduce(0, +),
                    countsByKind: countsByKind,
                    searchIndexRowCount: try clipboardItemSearchIndex.fetchCount(db),
                    databaseBytes: fileSize("yank.sqlite") + fileSize("yank.sqlite-wal"),
                    largeDataBytes: folderSize("LargeData"),
                    dataVersion: dataVersion)
            }
        }

        /// Every table in the file with its columns and row count, or nil when nothing has been
        /// written since `version` (see `snapshot(ifChangedSince:)`).
        public func tables(ifChangedSince version: Int?) throws -> TableList? {
            try queue.read { db in
                guard let dataVersion = try dataVersion(db, ifChangedSince: version) else {
                    return nil
                }
                // GRDB has no call that lists the tables, so this one line of SQL asks SQLite
                // directly. It returns everything, including the shadow tables FTS5 keeps behind
                // the search index and GRDB's own `grdb_migrations`, so a new table shows up here
                // without anyone remembering to add it. The app's own tables come first, then the
                // system and shadow ones (the ones with an underscore in the name).
                let names = try String.fetchAll(
                    db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
                let (own, system) = (names.filter { !$0.contains("_") }, names.filter { $0.contains("_") })
                let tables = try (own + system).map { name in
                    TableInfo(
                        name: name,
                        rowCount: try Table<Row>(name).fetchCount(db),
                        columns: try db.columns(in: name).map {
                            TableColumnInfo(name: $0.name, type: $0.type)
                        })
                }
                return TableList(tables: tables, dataVersion: dataVersion)
            }
        }

        /// `limit` rows of one table starting `offset` rows in, every column, as plain cells.
        /// Rows come in SQLite's own scan order, which for an ordinary table is rowid order:
        /// oldest first. Offset paging means page 500 of a 100,000-row table skips 99,800 rows
        /// on each read, a few milliseconds.
        public func page(of table: String, offset: Int, limit: Int) throws -> Page {
            try queue.read { db in
                let rows = try Table<Row>(table).all().limit(limit, offset: offset).fetchAll(db)
                return Page(rows: rows.map { row in row.map { Self.cell(for: $0.1) } })
            }
        }

        /// SQLite's change counter, or nil when it still equals `version`.
        nonisolated private func dataVersion(_ db: Database, ifChangedSince version: Int?) throws
            -> Int?
        {
            // `PRAGMA data_version` changes whenever a different connection has written to the
            // file. The query builder has no way to ask for it, so it is raw SQL.
            let dataVersion = try Int.fetchOne(db, sql: "PRAGMA data_version") ?? 0
            return dataVersion == version ? nil : dataVersion
        }

        /// A GRDB value as a plain `CellValue`. Blobs are sniffed: the PNG, JPEG or TIFF magic
        /// bytes make an image preview (whole data, so the cell can draw it); otherwise bytes
        /// that are valid UTF-8 make a short text preview. Anything else, or anything over
        /// `previewLimit`, is just a size.
        nonisolated private static func cell(for value: DatabaseValue) -> CellValue {
            switch value.storage {
            case .null: return .null
            case .int64(let n): return .integer(n)
            case .double(let d): return .real(d)
            case .string(let s): return .text(s)
            case .blob(let data):
                return .blob(byteCount: data.count, preview: preview(of: data))
            }
        }

        nonisolated private static func preview(of data: Data) -> BlobPreview? {
            guard !data.isEmpty, data.count <= previewLimit else { return nil }
            let imageMagics: [[UInt8]] = [
                [0x89, 0x50, 0x4E, 0x47],  // PNG
                [0xFF, 0xD8, 0xFF],  // JPEG
                [0x4D, 0x4D, 0x00, 0x2A], [0x49, 0x49, 0x2A, 0x00],  // TIFF
            ]
            if imageMagics.contains(where: { data.starts(with: $0) }) { return .image(data) }
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return .text(String(text.prefix(previewTextLength)))
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
