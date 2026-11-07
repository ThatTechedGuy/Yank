// GRDB (the SQLite library) may be imported only in this Storage/ folder, so all disk access
// stays behind the Store; scripts/check-imports.sh enforces that.
import GRDB

// The database schema, as numbered migrations. A migration is a named step that runs once per
// database, in order; GRDB records which ones have run in its own table, so an existing database
// gets only the steps it has not seen. ≈ Drizzle or Prisma migrations, or Room's
// `Migration(1, 2)`. Never edit a migration that has shipped, because users' databases have
// already run it and would never see the change: add a new one. v1 is everything capture needs
// plus the two tables later features fill (pinboard, cardThumbnail), so adding those features
// won't need a migration of existing users' data.
//
// Naming follows GRDB's defaults: singular camelCase table named after the Swift type, foreign
// keys as `<table>Id`. That lets GRDB map rows onto the model types with no mapping code.
enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // Each migration is a block that GRDB runs inside one transaction, so a failure halfway
        // leaves nothing behind. (`{ db in ... }` is a closure with one argument, ≈
        // `(db) => { ... }`.)
        migrator.registerMigration("v1") { db in
            // Pinboards: a named list you pin items to. Not used by capture yet. Created first
            // because clipboardItem's foreign key points at it.
            try db.create(table: "pinboard") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                // Where it sits in the sidebar, 0 first. Nothing else orders pinboards.
                t.column("position", .integer).notNull()
            }

            // One row per saved copy: what a list row needs to show itself (kind, title, card
            // text, source app, times). The clipboard bytes live in clipboardItemData, so
            // listing items never loads them.
            try db.create(table: "clipboardItem") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("title", .text)
                t.column("cardText", .text).notNull()
                t.column("sourceAppBundleId", .text)
                t.column("sourceAppName", .text)
                t.column("createdAt", .datetime).notNull()
                // Indexed because the list is always "newest copied first"; without the index
                // every list query would sort the whole table.
                t.column("copiedAt", .datetime).notNull().indexed()
                // Indexed because every save looks up "have we seen this content before?" and
                // must stay fast with thousands of items.
                t.column("contentFingerprint", .text).notNull().indexed()
                t.column("imageText", .text)
                t.column("linkPageTitle", .text)
                // Which pinboard the item is on, if any. `belongsTo` adds a `pinboardId` column
                // with a foreign key. Deleting a pinboard sets it to NULL: the items go back to
                // the main list, they are not lost.
                t.belongsTo("pinboard", onDelete: .setNull)
            }

            // One row per clipboard type of one item (an image copy has a PNG row, a TIFF row,
            // and so on). `data` holds up to 1 MB; larger data is in a file named by
            // `largeDataFileName` (see LargeDataFiles). Exactly one of the two is set.
            try db.create(table: "clipboardItemData") { t in
                t.autoIncrementedPrimaryKey("id")
                // Deleting the item deletes its data rows too (ON DELETE CASCADE), so nothing
                // has to delete them by hand. `indexed()` so "all data of item 12" is a lookup,
                // not a scan.
                t.belongsTo("clipboardItem", onDelete: .cascade).notNull()
                t.column("pasteboardItemIndex", .integer).notNull()
                // Where this type stood in the source app's list, 0 first. A paste
                // replays the types in that order, because the first is the app's best one.
                t.column("position", .integer).notNull()
                t.column("type", .text).notNull()
                t.column("data", .blob)
                t.column("largeDataFileName", .text)
            }

            // The small PNG a card shows for an image item, so a scrolling list never has to
            // decode the full-size image. One per item at most, so the item's id is the primary
            // key, and it goes away with the item.
            try db.create(table: "cardThumbnail") { t in
                t.primaryKey { t.belongsTo("clipboardItem", onDelete: .cascade) }
                t.column("png", .blob).notNull()
                t.column("width", .integer).notNull()
                t.column("height", .integer).notNull()
            }

            // Full-text search over the searchable text columns. FTS5 is SQLite's built-in
            // search engine: it keeps its own index of the words in these columns so a search
            // doesn't scan every row. `synchronize(withTable:)` makes SQLite keep that index up
            // to date with triggers, so saves and deletes don't have to touch it. Prefixes 2
            // and 3 make "search as you type" fast from the second letter.
            try db.create(virtualTable: "clipboardItemSearchIndex", using: FTS5()) { t in
                t.synchronize(withTable: "clipboardItem")
                t.tokenizer = .unicode61()
                t.prefixes = [2, 3]
                t.column("cardText")
                t.column("title")
                t.column("imageText")
                t.column("linkPageTitle")
            }
        }
        return migrator
    }
}
