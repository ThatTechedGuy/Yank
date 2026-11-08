import Foundation

// Which cards are selected in the panel, and how the keys and clicks change that. The panel
// shows an ordered list of items; this value only knows their ids and is told the order on
// every call, so it stays a pure value with no view inside (≈ a reducer over `{ anchor, lead,
// ids }`). A plain click selects one card; ⇧← and ⇧→ grow or shrink a run of cards from
// where the selection started; ⌘-click adds or removes a single card anywhere; ⌘A takes the
// whole list. When the list changes (a search, another tab, a delete), `keep(in:)` drops what
// is no longer shown.
/// The selected cards: a lead card the keys move, an anchor the run starts from, and the set.
public struct CardSelection: Equatable, Sendable {
    /// The card the keys move and the outline follows: the one a single-card panel would call
    /// "the selected card". Nil when nothing is selected.
    public private(set) var lead: Int64?
    /// Where a ⇧-arrow run starts; the lead is its other end.
    public private(set) var anchor: Int64?
    /// Every selected card, in no particular order. Use `ordered(in:)` for left-to-right.
    public private(set) var ids: Set<Int64> = []

    public init() {}

    public var count: Int { ids.count }

    public func contains(_ id: Int64) -> Bool { ids.contains(id) }

    /// Selects just this card. Nil clears the selection.
    public mutating func select(_ id: Int64?) {
        lead = id
        anchor = id
        ids = id.map { [$0] } ?? []
    }

    /// ⇧← (step -1) or ⇧→ (step +1): moves the lead one card along `order` and selects every
    /// card between the anchor and the new lead. Stays put at either end. A selection made
    /// with ⌘-clicks loses its scattered cards: the run from the anchor replaces them.
    public mutating func extend(by step: Int, in order: [Int64]) {
        guard let lead, let leadIndex = order.firstIndex(of: lead) else {
            select(order.first)
            return
        }
        let target = leadIndex + step
        guard order.indices.contains(target) else { return }
        let anchorIndex = anchor.flatMap { order.firstIndex(of: $0) } ?? leadIndex
        self.lead = order[target]
        anchor = order[anchorIndex]
        ids = Set(order[min(anchorIndex, target)...max(anchorIndex, target)])
    }

    /// ⌘-click: adds the card if it is not selected, removes it if it is. A card added this
    /// way becomes the lead and the anchor, so a ⇧-arrow afterwards runs from it. Removing the
    /// last card leaves nothing selected.
    public mutating func toggle(_ id: Int64) {
        if ids.contains(id) {
            ids.remove(id)
            if lead == id { lead = ids.first }
            if anchor == id { anchor = lead }
        } else {
            ids.insert(id)
            lead = id
            anchor = id
        }
    }

    /// ⌘A: every card in the list. The lead stays where it was, or goes to the first card.
    public mutating func selectAll(in order: [Int64]) {
        ids = Set(order)
        if lead.map({ !ids.contains($0) }) ?? true { lead = order.first }
        anchor = order.first
    }

    /// The list changed: forgets cards that are no longer in it. If the lead went, the first
    /// card of the new list takes over, so the panel always has a card to paste.
    public mutating func keep(in order: [Int64]) {
        ids.formIntersection(order)
        if let lead, ids.contains(lead) { return }
        select(order.first)
    }

    /// The selected cards in the list's order (left to right), the order a paste of several
    /// cards uses.
    public func ordered(in order: [Int64]) -> [Int64] {
        order.filter(ids.contains)
    }
}
