import Foundation
import GRDB

// How the Store talks to the tables without writing SQL by hand. GRDB's "record" API is its
// ORM: a Swift type that says which table it belongs to can be fetched (`fetchOne`, `fetchAll`,
// `fetchCount`), filtered and ordered (`filter`, `order`), inserted (`insert`), updated
// (`update`) and deleted (`deleteAll`), and GRDB writes the SQL. ≈ Drizzle or Prisma models, or
// Room entities. The column names come from the property names, which is why the model
// properties are named exactly like the columns in Migrations.
//
// These conformances live here, not on the model files, so only Storage/ knows GRDB exists.

// `FetchableRecord`: GRDB can build a `ClipboardItem` from a row (it already is `Decodable`).
// `PersistableRecord`: GRDB can write one back with `update(db)` (it already is `Encodable`).
// The table name comes from the type name: "clipboardItem". Inserts don't use this type, see
// `NewClipboardItem` below.
extension ClipboardItem: FetchableRecord, PersistableRecord {
    /// Every item, newest copied first: the order the panel shows them in. The `id` tie-break
    /// keeps two items copied in the same second in a fixed order, so paging never shows one
    /// twice or skips one.
    static var newestFirst: QueryInterfaceRequest<ClipboardItem> {
        order(ClipboardItemColumns.copiedAt.desc, ClipboardItemColumns.id.desc)
    }

    /// An item's row in the search index. The index has no id column of its own: SQLite gives
    /// every row a hidden `rowid`, and the sync triggers keep it equal to the item's `id`, so
    /// that is the link. ≈ a one-to-one relation in Prisma, declared so the Store can `JOIN`
    /// the two tables with the query builder instead of writing the join by hand.
    static let searchIndex = hasOne(clipboardItemSearchIndex, using: ForeignKey(["rowid"], to: ["id"]))
}

// Named columns of `clipboardItem` for `filter` and `order`, so the Store never repeats a column
// name as a string and a typo shows up in one place. (Swift keeps a public type's generated
// `CodingKeys` private to its own file, so these are spelled out; they must match the property
// names in ClipboardItem.swift. A separate enum, not one nested in `ClipboardItem`, because GRDB
// reserves a nested `Columns` for its own use.)
enum ClipboardItemColumns {
    static let id = Column("id")
    static let copiedAt = Column("copiedAt")
    static let contentFingerprint = Column("contentFingerprint")
}

// A clipboard item about to be inserted. It has every column of `clipboardItem` except `id`,
// because the database hands out the id on insert; a `ClipboardItem` always has an id, so it
// can't stand in for a row that has none yet. Inserting one with `insertAndFetch` returns the
// full `ClipboardItem` as stored, id and all. `kind` and `cardText` and the rest mirror the
// model on purpose: the column names must match.
struct NewClipboardItem: Encodable, PersistableRecord {
    static let databaseTableName = ClipboardItem.databaseTableName

    var kind: ItemKind
    var cardText: String
    var sourceAppBundleId: String?
    var sourceAppName: String?
    var createdAt: Date
    var copiedAt: Date
    var contentFingerprint: String
}

// One row of `clipboardItemData`, with the storage-only columns the public `ClipboardItemData`
// doesn't carry: the row id, which item it belongs to, its position and the large-data file
// name. The Store turns these into `ClipboardItemData` values when reading, so nobody outside
// Storage/ sees file names or row ids. `id` is optional because it is nil until the insert.
struct ClipboardItemDataRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "clipboardItemData"

    var id: Int64?
    var clipboardItemId: Int64
    var pasteboardItemIndex: Int
    var position: Int
    var type: String
    /// The bytes, when small enough to live in the row; nil when they are in a file.
    var data: Data?
    /// The file holding the bytes, when they were too big for the row; nil otherwise.
    var largeDataFileName: String?

    enum Columns {  // typed column names, built from the property names so they can't drift
        static let clipboardItemId = Column(CodingKeys.clipboardItemId)
        static let position = Column(CodingKeys.position)
        static let largeDataFileName = Column(CodingKeys.largeDataFileName)
    }

    /// The rows of one item, in the source app's order.
    static func ofItem(_ itemId: Int64) -> QueryInterfaceRequest<ClipboardItemDataRow> {
        filter(Columns.clipboardItemId == itemId).order(Columns.position)
    }

    /// Just the file names, from any request for rows. Rows without a file are skipped.
    static func fileNames(in request: QueryInterfaceRequest<ClipboardItemDataRow>)
        -> QueryInterfaceRequest<String>
    {
        request.filter(Columns.largeDataFileName != nil)
            .select(Columns.largeDataFileName, as: String.self)
    }
}

// The full-text search table has no Swift model (it is an index, not data we read back), so it
// is addressed by name. `Table` gives it the same `filter`/`matching`/`fetchCount` builder.
let clipboardItemSearchIndex = Table("clipboardItemSearchIndex")
