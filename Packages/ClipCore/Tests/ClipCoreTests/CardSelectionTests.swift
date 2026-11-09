import Testing

@testable import ClipCore

// The selection as the keys and clicks drive it, over a fixed list of five card ids. The
// expected sets are written out by hand from the rules, so a wrong range or a lost anchor
// shows up as a different set.
struct CardSelectionTests {
    let order: [Int64] = [10, 20, 30, 40, 50]

    @Test func shiftArrowsGrowFromTheAnchorAndShrinkBackPastIt() {
        var selection = CardSelection()
        selection.select(30)
        selection.extend(by: 1, in: order)
        selection.extend(by: 1, in: order)
        #expect(selection.ids == [30, 40, 50])
        #expect(selection.lead == 50)
        // At the end: stays put.
        selection.extend(by: 1, in: order)
        #expect(selection.ids == [30, 40, 50])
        // Back past the anchor: the run flips to the other side of it.
        for _ in 0..<3 { selection.extend(by: -1, in: order) }
        #expect(selection.ids == [20, 30])
        #expect(selection.anchor == 30)
        #expect(selection.lead == 20)
    }

    @Test func commandClickTogglesOneCardAnywhere() {
        var selection = CardSelection()
        selection.select(10)
        selection.toggle(40)
        #expect(selection.ids == [10, 40])
        #expect(selection.lead == 40)
        selection.toggle(10)
        #expect(selection.ids == [40])
        // Removing the last selected card leaves nothing, and the next arrow starts over.
        selection.toggle(40)
        #expect(selection.ids.isEmpty)
        #expect(selection.lead == nil)
        selection.extend(by: 1, in: order)
        #expect(selection.ids == [10])
    }

    @Test func selectAllTakesTheWholeListAndKeepsTheLead() {
        var selection = CardSelection()
        selection.select(30)
        selection.selectAll(in: order)
        #expect(selection.ids == Set(order))
        #expect(selection.lead == 30)
    }

    @Test func aChangedListDropsWhatItNoLongerShows() {
        var selection = CardSelection()
        selection.select(20)
        selection.extend(by: 1, in: order)
        // A search narrows the list to two cards, one of them selected: it stays, alone.
        selection.keep(in: [30, 50])
        #expect(selection.ids == [30])
        #expect(selection.lead == 30)
        // The selected card is deleted: the first card of the new list takes over.
        selection.keep(in: [50, 60])
        #expect(selection.ids == [50])
        #expect(selection.lead == 50)
        // An empty list: nothing selected, and nothing crashes.
        selection.keep(in: [])
        #expect(selection.ids.isEmpty)
        #expect(selection.lead == nil)
    }
}
