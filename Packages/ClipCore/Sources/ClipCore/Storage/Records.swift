import Foundation
import GRDB

// GRDB record conformances for the model types. They live here, not on the models, so only
// Storage/ knows GRDB exists. Column names come from property names, so the model properties must
// be named exactly like the columns in Migrations.

// Inserts go through `NewClipboardItem` below.
extension ClipboardItem: FetchableRecord, PersistableRecord {
    /// Every item, newest copied first: the order the panel shows them in. The `id` tie-break
    /// keeps items with the same `copiedAt` in a fixed order, so paging never repeats or skips one.
    static var newestFirst: QueryInterfaceRequest<ClipboardItem> {
        order(ClipboardItemColumns.copiedAt.desc, ClipboardItemColumns.id.desc)
    }

    /// The items the panel shows for a filter, newest first. `now` and `calendar` are passed in
    /// so the date maths stays testable (see `DateRange`).
    static func matching(_ filter: ItemFilter, now: Date, calendar: Calendar)
        -> QueryInterfaceRequest<ClipboardItem>
    {
        var request = newestFirst
        switch filter.list {
        case .history: request = request.filter(ClipboardItemColumns.pinboardId == nil)
        case .pinboard(let id): request = request.filter(ClipboardItemColumns.pinboardId == id)
        }
        if let kind = filter.kind {
            request = request.filter(ClipboardItemColumns.kind == kind.rawValue)
        }
        if let start = filter.dateRange.start(now: now, calendar: calendar) {
            request = request.filter(ClipboardItemColumns.copiedAt >= start)
        }
        return request
    }

    /// An item's row in the search index. The index has no id column of its own: the sync
    /// triggers keep its `rowid` equal to the item's `id`, so that is the link.
    static let searchIndex = hasOne(clipboardItemSearchIndex, using: ForeignKey(["rowid"], to: ["id"]))
}

// Spelled out because a public type's synthesised `CodingKeys` are private to its own file; they
// must match the property names in ClipboardItem.swift. A separate enum, not one nested in
// `ClipboardItem`, because GRDB reserves a nested `Columns` for its own use.
enum ClipboardItemColumns {
    static let id = Column("id")
    static let kind = Column("kind")
    static let title = Column("title")
    static let cardDetail = Column("cardDetail")
    static let imageText = Column("imageText")
    static let linkPageTitle = Column("linkPageTitle")
    static let copiedAt = Column("copiedAt")
    static let contentFingerprint = Column("contentFingerprint")
    static let pinboardId = Column("pinboardId")
    static let searchText = Column("searchText")
}

// Inserts go through `NewPinboard` below, for the same reason as `NewClipboardItem`.
extension Pinboard: FetchableRecord, PersistableRecord {
    /// Every pinboard in tab order.
    static var inOrder: QueryInterfaceRequest<Pinboard> {
        order(PinboardColumns.position, PinboardColumns.id)
    }
}

enum PinboardColumns {
    static let id = Column("id")
    static let name = Column("name")
    static let position = Column("position")
}

// A pinboard about to be inserted: every column but `id`.
struct NewPinboard: Encodable, PersistableRecord {
    static let databaseTableName = Pinboard.databaseTableName

    var name: String
    var position: Int
}

// The primary key is the item's id, so `upsert` replaces the item's old thumbnail in place.
extension CardThumbnail: FetchableRecord, PersistableRecord {}

// A clipboard item about to be inserted: every column but `id`, which the database hands out; a
// `ClipboardItem` always has one, so it can't stand in for a row that has none yet. The optional
// columns default to nil for a fresh copy; a duplicate fills them from the original. `searchText`
// is here and not on `ClipboardItem` on purpose: it can be thousands of characters and only the
// search index reads it, so the cards never carry it around.
struct NewClipboardItem: Encodable, PersistableRecord {
    static let databaseTableName = ClipboardItem.databaseTableName

    var kind: ItemKind
    var title: String? = nil
    var cardText: String
    var searchText: String
    var cardDetail: String?
    var sourceAppBundleId: String?
    var sourceAppName: String?
    var createdAt: Date
    var copiedAt: Date
    var contentFingerprint: String
    var imageText: String? = nil
    var linkPageTitle: String? = nil
    var pinboardId: Int64? = nil
}

// One row of `clipboardItemData`, with the storage-only columns the public `ClipboardItemData`
// doesn't carry (row id, item id, position, file name), so nobody outside Storage/ sees them.
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

    /// The rows of every item a request finds: what erasing or expiring items removes.
    static func ofItems(in items: QueryInterfaceRequest<ClipboardItem>)
        -> QueryInterfaceRequest<ClipboardItemDataRow>
    {
        filter(items.select(ClipboardItemColumns.id, as: Int64.self).contains(Columns.clipboardItemId))
    }

    /// Just the file names, from any request for rows. Rows without a file are skipped.
    static func fileNames(in request: QueryInterfaceRequest<ClipboardItemDataRow>)
        -> QueryInterfaceRequest<String>
    {
        request.filter(Columns.largeDataFileName != nil)
            .select(Columns.largeDataFileName, as: String.self)
    }
}

// The search index has no Swift model (it is an index, not data read back), so it is addressed
// by name.
let clipboardItemSearchIndex = Table("clipboardItemSearchIndex")
