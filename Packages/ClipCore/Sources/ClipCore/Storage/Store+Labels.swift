import Foundation
import GRDB

// The label side of the Store: the category list, the queue of items waiting for the model, and
// the labels themselves. Kept apart from Store.swift, which is about saving and reading copies.
extension Store {
    /// Marks a text that holds a key as a Credential (where not set by hand), or queues it for
    /// the model. The caller saves `item`.
    static func labelOrQueue(_ db: Database, _ item: inout ClipboardItem, text: String) throws {
        if Credentials.detect(String(text.prefix(Labels.inputLength))) {
            if !item.categorySetByHand { item.categoryId = ItemCategory.credentialId }
            if !item.languageSetByHand { item.language = Language.none }
            // It may have been queued as the text it held before; the model must never read a key.
            _ = try LabelQueueEntry.deleteOne(db, key: item.id)
        } else {
            try LabelQueueEntry(clipboardItemId: item.id).upsert(db)
        }
    }

    /// The categories in list order, delivered now and again whenever one changes.
    public func observeCategories() -> some AsyncSequence<[ItemCategory], any Error> {
        ValueObservation
            .tracking { db in try ItemCategory.inOrder.fetchAll(db) }
            .removeDuplicates()
            .values(in: pool)
    }

    /// The categories in list order, once.
    public func categories() async throws -> [ItemCategory] {
        try await pool.read { db in try ItemCategory.inOrder.fetchAll(db) }
    }

    /// Adds a category at the end of the list, and queues the history to be labelled again when
    /// it has a description.
    /// Nil when the name is blank or another category has it: the model is handed the names as
    /// a list of choices, which must be distinct.
    @discardableResult
    public func createCategory(named name: String, about: String) async throws -> ItemCategory? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await pool.write { db in
            guard try Self.isFreeName(db, name, besides: nil) else { return nil }
            let last = try ItemCategory.select(max(ItemCategoryColumns.position), as: Int.self).fetchOne(db)
            let category = try NewItemCategory(
                name: name, about: about.trimmingCharacters(in: .whitespacesAndNewlines),
                position: (last ?? -1) + 1
            ).insertAndFetch(db, as: ItemCategory.self)
            // The model is not offered a category without a description (see Enricher), so the
            // history is labelled again once it has one.
            if !category.about.isEmpty { try Self.queueAllForLabels(db) }
            return category
        }
    }

    /// Saves a category's name and description. A blank or taken name is left as it was; the
    /// description is saved either way. Its items keep it: they point at it by id.
    public func updateCategory(id: Int64, name: String, about: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await pool.write { db in
            guard let old = try ItemCategory.fetchOne(db, key: id) else { return }
            var category = old
            if try Self.isFreeName(db, name, besides: id) { category.name = name }
            category.about = about.trimmingCharacters(in: .whitespacesAndNewlines)
            guard category != old else { return }
            try category.update(db)
            try Self.queueAllForLabels(db)
        }
    }

    /// Puts the categories in this order, first to last.
    public func reorderCategories(ids: [Int64]) async throws {
        try await pool.write { db in
            for (position, id) in ids.enumerated() {
                _ = try ItemCategory.filter(key: id).updateAll(
                    db, [ItemCategoryColumns.position.set(to: position)])
            }
            try Self.queueAllForLabels(db)
        }
    }

    /// Removes a category; its items move to Other. Other and Credential cannot be removed.
    public func deleteCategory(id: Int64) async throws {
        guard id != ItemCategory.otherId, id != ItemCategory.credentialId else { return }
        try await pool.write { db in
            _ = try ClipboardItem.filter(ClipboardItemColumns.categoryId == id)
                .updateAll(db, [ClipboardItemColumns.categoryId.set(to: ItemCategory.otherId)])
            guard try ItemCategory.deleteOne(db, key: id) else { return }
            try Self.queueAllForLabels(db)
        }
    }

    private static func isFreeName(_ db: Database, _ name: String, besides id: Int64?) throws -> Bool {
        guard !name.isEmpty else { return false }
        return try !ItemCategory.fetchAll(db).contains {
            $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// Queues every item the model may label again: what the model can read, minus a category
    /// set by hand and the credentials, which the model never sees. Hand-written SQL because the
    /// query builder has no INSERT … SELECT, and one statement keeps a 100,000-item history fast.
    private static func queueAllForLabels(_ db: Database) throws {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO labelQueue (clipboardItemId)
                SELECT id FROM clipboardItem
                WHERE (kind = 'text' OR (kind = 'image' AND imageText <> ''))
                  AND categorySetByHand = 0 AND (categoryId IS NULL OR categoryId <> ?)
                """, arguments: [ItemCategory.credentialId])
    }

    /// The next queued item for the model, pinned items first, then newest, with the text to
    /// read: a text's start, an image's words. Nil when the queue is empty.
    public func nextToLabel() async throws -> (item: ClipboardItem, text: String)? {
        try await pool.read { db in
            // Two queries that each walk an index and stop at the first queued item: 0.3 ms at
            // 100,000 items, where one query sorting the whole queue took 32 ms. Pinned items come in no
            // particular order, and `> 0` rather than `IS NOT NULL`, which SQLite answered by
            // reading every item (5 ms); ids start at 1.
            let queued = ClipboardItem.joining(required: ClipboardItem.labelQueueEntry)
            guard
                let item = try queued.filter(ClipboardItemColumns.pinboardId > 0).fetchOne(db)
                    ?? queued.filter(ClipboardItemColumns.pinboardId == nil)
                    .order(ClipboardItemColumns.copiedAt.desc, ClipboardItemColumns.id.desc).fetchOne(db)
            else { return nil }
            let text =
                item.kind == .image
                ? item.imageText
                : try ClipboardItem.filter(key: item.id)
                    .select(ClipboardItemColumns.searchText, as: String.self).fetchOne(db)
            return (item, String((text ?? "").prefix(Labels.inputLength)))
        }
    }

    /// Saves the model's labels and takes the item off the queue. A category or language set by
    /// hand stays.
    public func setLabels(categoryId: Int64, language: String, title: String?, for itemId: Int64) async throws
    {
        try await pool.write { db in
            // One update, not three: each update of the row makes the search index rewrite it.
            if var item = try ClipboardItem.fetchOne(db, key: itemId) {
                item.labelTitle = title
                if !item.categorySetByHand { item.categoryId = categoryId }
                if !item.languageSetByHand { item.language = language }
                try item.update(db)
            }
            _ = try LabelQueueEntry.deleteOne(db, key: itemId)
        }
    }

    /// Takes an item off the queue unlabelled, when the model could not label it.
    public func dropFromLabelQueue(itemId: Int64) async throws {
        _ = try await pool.write { db in try LabelQueueEntry.deleteOne(db, key: itemId) }
    }

    /// The category the user picked in the actions menu. The model never changes it again.
    public func setCategory(_ categoryId: Int64, for itemId: Int64) async throws {
        _ = try await pool.write { db in
            try ClipboardItem.filter(key: itemId).updateAll(
                db,
                [
                    ClipboardItemColumns.categoryId.set(to: categoryId),
                    ClipboardItemColumns.categorySetByHand.set(to: true),
                ])
        }
    }

    /// The language the user picked in the actions menu. The model never changes it again.
    public func setLanguage(_ language: String, for itemId: Int64) async throws {
        _ = try await pool.write { db in
            try ClipboardItem.filter(key: itemId).updateAll(
                db,
                [
                    ClipboardItemColumns.language.set(to: language),
                    ClipboardItemColumns.languageSetByHand.set(to: true),
                ])
        }
    }
}
