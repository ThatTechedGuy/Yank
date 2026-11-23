// GRDB (the SQLite library) may be imported only in this Storage/ folder, so all disk access
// stays behind the Store; scripts/check-imports.sh enforces that.
import GRDB

// The database schema, as numbered migrations. Never edit a migration that has shipped: users'
// databases have already run it and would never see the change, so add a new one. Naming follows
// GRDB's defaults (table named after the Swift type, foreign keys as `<table>Id`), so no mapping code.
enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            // Created first because clipboardItem's foreign key points at it.
            try db.create(table: "pinboard") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                // Where it sits in the tab row, 0 first. Nothing else orders pinboards.
                t.column("position", .integer).notNull()
            }

            // One row per saved copy: what a list row needs to show itself. The clipboard bytes
            // live in clipboardItemData, so listing items never loads them.
            try db.create(table: "clipboardItem") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("title", .text)
                t.column("cardText", .text).notNull()
                t.column("sourceAppBundleId", .text)
                t.column("sourceAppName", .text)
                t.column("createdAt", .datetime).notNull()
                // Indexed because the list is always "newest copied first".
                t.column("copiedAt", .datetime).notNull().indexed()
                // Indexed because every save looks up "have we seen this content before?".
                t.column("contentFingerprint", .text).notNull().indexed()
                t.column("imageText", .text)
                t.column("linkPageTitle", .text)
                // Deleting a pinboard sets this to NULL: its items go back to the main list,
                // they are not lost.
                t.belongsTo("pinboard", onDelete: .setNull)
            }

            // One row per clipboard type of one item (an image copy has a PNG row, a TIFF row,
            // and so on). `data` holds up to 1 MB; larger data is in a file named by
            // `largeDataFileName` (see LargeDataFiles). Exactly one of the two is set.
            try db.create(table: "clipboardItemData") { t in
                t.autoIncrementedPrimaryKey("id")
                // Deleting the item deletes its data rows too. `belongsTo` also indexes the
                // column, so "all data of item 12" is a lookup, not a scan.
                t.belongsTo("clipboardItem", onDelete: .cascade).notNull()
                t.column("pasteboardItemIndex", .integer).notNull()
                // Where this type stood in the source app's list, 0 first. A paste replays the
                // types in that order, because the first is the app's best one.
                t.column("position", .integer).notNull()
                t.column("type", .text).notNull()
                t.column("data", .blob)
                t.column("largeDataFileName", .text)
            }

            // The small PNG a card shows, so a scrolling list never has to decode the full-size
            // image. One per item at most, so the item's id is the primary key.
            try db.create(table: "cardThumbnail") { t in
                t.primaryKey { t.belongsTo("clipboardItem", onDelete: .cascade) }
                t.column("png", .blob).notNull()
                t.column("width", .integer).notNull()
                t.column("height", .integer).notNull()
            }

            // The search index. Triggers keep it in sync with clipboardItem, so saves and deletes
            // don't have to touch it. Prefixes 2 and 3 make "search as you type" fast from the
            // second letter.
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

        // Search also matches the app an item was copied from ("safari" finds Safari copies). An
        // FTS5 table cannot gain a column, so the index is dropped and made again; GRDB fills the
        // new one from every existing row. The sync triggers from v1 live on clipboardItem, not on
        // the index, so dropping the index leaves them behind and they must be removed by hand
        // before new ones are created.
        migrator.registerMigration("v2") { db in
            try db.drop(table: "clipboardItemSearchIndex")
            try db.dropFTS5SynchronizationTriggers(forTable: "clipboardItemSearchIndex")
            try db.create(virtualTable: "clipboardItemSearchIndex", using: FTS5()) { t in
                t.synchronize(withTable: "clipboardItem")
                t.tokenizer = .unicode61()
                t.prefixes = [2, 3]
                t.column("cardText")
                t.column("title")
                t.column("imageText")
                t.column("linkPageTitle")
                t.column("sourceAppName")
            }
        }

        // The card footer's one line ("52 characters", "212 KB", "1280 × 800"). Items saved before
        // it stay NULL and the card shows nothing there. Not in the search index: nobody searches
        // for "212 KB".
        migrator.registerMigration("v3") { db in
            try db.alter(table: "clipboardItem") { t in
                t.add(column: "cardDetail", .text)
            }
        }

        // Search used to read `cardText`, the 200 characters on the card, so a word further into
        // a long text was never found. The new `searchText` column holds much more of it, and the
        // index reads that instead; rebuilt the same way as v2. Existing text items are filled
        // from their saved plain text, in hand-written SQL because the query builder cannot say
        // "set a column from a subquery that casts a blob". An item whose text was over 1 MB has
        // it in a file SQL cannot read, so it keeps its card text, as does every other kind. 20000
        // is `CardText.maxSearchLength` at the time of writing, spelled out because a migration
        // must keep doing what it did even if that constant later changes.
        migrator.registerMigration("v4") { db in
            try db.drop(table: "clipboardItemSearchIndex")
            try db.dropFTS5SynchronizationTriggers(forTable: "clipboardItemSearchIndex")
            try db.alter(table: "clipboardItem") { t in
                t.add(column: "searchText", .text).notNull().defaults(to: "")
            }
            try db.execute(
                sql: """
                    UPDATE clipboardItem SET searchText = CASE WHEN kind = 'text' THEN COALESCE(
                        (SELECT substr(CAST(data AS TEXT), 1, 20000) FROM clipboardItemData
                         WHERE clipboardItemId = clipboardItem.id
                           AND type = 'public.utf8-plain-text' AND data IS NOT NULL
                         ORDER BY position LIMIT 1),
                        cardText) ELSE cardText END
                    """)
            try db.create(virtualTable: "clipboardItemSearchIndex", using: FTS5()) { t in
                t.synchronize(withTable: "clipboardItem")
                t.tokenizer = .unicode61()
                t.prefixes = [2, 3]
                t.column("searchText")
                t.column("title")
                t.column("imageText")
                t.column("linkPageTitle")
                t.column("sourceAppName")
            }
        }

        // The panel's list is `WHERE pinboardId IS NULL` (or `= ?`) `ORDER BY copiedAt DESC, id
        // DESC`. The `id` tiebreak is not in v1's `copiedAt` index, so SQLite sorted every row of
        // the tab for each page: 48 ms at 100,000 items. This index holds the filter and the whole
        // order, so a page is a lookup (0.1 ms).
        migrator.registerMigration("v5") { db in
            try db.create(indexOn: "clipboardItem", columns: ["pinboardId", "copiedAt", "id"])
        }

        // Labels: the user's categories, and on each item a category, a language and the model's
        // short title (`labelTitle`, kept apart from `title`, which only Rename sets). The two
        // `…SetByHand` flags keep a hand correction from the model. `labelQueue` holds the items
        // the Enricher still has to label; it is a table of its own because any update of a
        // clipboardItem row makes the search index's triggers rewrite that row's entry, so
        // queueing the whole history on a list change would rewrite the whole index. Every
        // existing text item and image with words joins the queue, except the credentials found
        // here, which the model never sees. The starting list goes in by hand-written SQL with
        // fixed ids, because `ItemCategory.otherId` and `.credentialId` name rows 8 and 4.
        // Credentials are spotted with `Credentials.detect` as it is today, in the first 1,500
        // characters, as a save does (`Labels.inputLength`, spelled out like v4's 20000); a later
        // change to it reaches only new copies, which is fine for a label.
        migrator.registerMigration("v6") { db in
            try db.create(table: "itemCategory") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("about", .text).notNull()
                t.column("position", .integer).notNull()
            }
            let starting = [
                ("Code", "Source code in a programming language: a function, a class, a snippet."),
                ("Command", "A command to run in a terminal, such as git, npm or brew with its arguments."),
                ("Error or log", "An error message, a stack trace, or lines from a log file."),
                ("Credential", "A password, an API key, a token or a private key."),
                (
                    "Address or contact",
                    "A postal address, an email address, a phone number or someone's details."
                ),
                ("Prose", "Sentences written for people: a message, an email, notes, an article."),
                ("Data", "Structured data: JSON, CSV, a table, a list of values or numbers."),
                ("Other", "Anything that fits none of the other categories."),
            ]
            for (index, (name, about)) in starting.enumerated() {
                try db.execute(
                    sql: "INSERT INTO itemCategory (id, name, about, position) VALUES (?, ?, ?, ?)",
                    arguments: [index + 1, name, about, index])
            }
            try db.alter(table: "clipboardItem") { t in
                // Removing a category moves its items to Other first (Store.deleteCategory).
                t.add(column: "categoryId", .integer).references("itemCategory", onDelete: .setNull)
                t.add(column: "language", .text)
                t.add(column: "labelTitle", .text)
                t.add(column: "categorySetByHand", .boolean).notNull().defaults(to: false)
                t.add(column: "languageSetByHand", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "labelQueue") { t in
                t.primaryKey { t.belongsTo("clipboardItem", onDelete: .cascade) }
            }
            // Everything labelable joins the queue in one statement, then the keys leave it.
            // The rows are read through a cursor, one at a time, so a big history is never all
            // in memory; it only collects ids, because nothing may be written mid-cursor.
            let labelable = "kind = 'text' OR (kind = 'image' AND imageText <> '')"
            try db.execute(
                sql:
                    "INSERT INTO labelQueue (clipboardItemId) SELECT id FROM clipboardItem WHERE \(labelable)"
            )
            var credentialIds: [Int64] = []
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT id, substr(CASE WHEN kind = 'text' THEN searchText ELSE imageText END, 1, 1500)
                        AS text
                    FROM clipboardItem WHERE \(labelable)
                    """)
            while let row = try rows.next() {
                if Credentials.detect(row["text"]) { credentialIds.append(row["id"]) }
            }
            for id in credentialIds {
                try db.execute(
                    sql: "UPDATE clipboardItem SET categoryId = 4, language = 'none' WHERE id = ?",
                    arguments: [id])
                try db.execute(sql: "DELETE FROM labelQueue WHERE clipboardItemId = ?", arguments: [id])
            }
        }
        return migrator
    }
}
