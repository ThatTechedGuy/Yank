import Foundation

// One value carries the list, the kind and the date, so the live list and the search take the
// same argument and can never disagree about what is filtered. `Hashable` so the model can tell
// whether a change really changed anything before it restarts a query.
/// What the panel shows: the list, and the kind and date it is narrowed to.
public struct ItemFilter: Hashable, Sendable {
    /// The History tab (items on no pinboard) or one pinboard's tab (its items).
    public var list: ItemList = .history
    /// Only this kind of item, or nil for every kind.
    public var kind: ItemKind?
    /// Only items copied in this range.
    public var dateRange: DateRange = .anyTime

    public init(list: ItemList = .history, kind: ItemKind? = nil, dateRange: DateRange = .anyTime) {
        self.list = list
        self.kind = kind
        self.dateRange = dateRange
    }

    /// Whether the kind or the date narrows the list. The filter button shows this.
    public var isNarrowed: Bool { kind != nil || dateRange != .anyTime }
}

/// Which list the panel shows: everything not pinned, or the items of one pinboard.
public enum ItemList: Hashable, Sendable {
    /// Items on no pinboard: what "Erase History" removes.
    case history
    /// The items of the pinboard with this id.
    case pinboard(id: Int64)
}
