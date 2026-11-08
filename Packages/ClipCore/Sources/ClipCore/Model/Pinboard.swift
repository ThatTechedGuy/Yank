import Foundation

// A named list of items the user wants to keep: "Snippets", "Work". A row of the `pinboard`
// table, and one tab in the panel. An item sits on at most one pinboard (its `pinboardId`), so
// pinning moves it off the History tab and onto the pinboard's tab, and deleting the pinboard
// sends its items back. Pinned items are what "Erase History" leaves alone.
//
// The protocols do the same jobs as on `ClipboardItem`: `Identifiable` for SwiftUI lists,
// `Codable` so the Store maps rows onto it by property name, `Hashable` and `Sendable` so it
// can be compared, put in sets and passed between threads.
/// A named list of kept items. ≈ a row of `pinboard`.
public struct Pinboard: Identifiable, Hashable, Sendable, Codable {
    /// SQLite's row id, assigned on insert.
    public var id: Int64
    /// What the tab says. Set when created, changed by Rename.
    public var name: String
    /// Where the tab sits among the pinboards, 0 first. Nothing else orders them.
    public var position: Int

    public init(id: Int64, name: String, position: Int) {
        self.id = id
        self.name = name
        self.position = position
    }
}
