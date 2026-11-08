// A card's actions and selecting several, as a user meets them: ⌘K opens the actions list
// above the selected card, ↑ ↓ and Return pick one, Delete asks and then the card is gone;
// ⇧→ grows the selection to two cards, and ⌫ asks before deleting them. Launched with a fake
// history, like PanelTests. (See LaunchTests for what XCTest and XCUIApplication are.)
import XCTest

final class ActionsTests: XCTestCase {
    @MainActor
    func testCommandKDeletesTheSelectedCard() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed", "20", "--show-panel"]
        app.launch()
        let search = app.textFields["search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let cards = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'card-'"))
        let first = cards.element(boundBy: 0)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let firstCard = app.staticTexts[first.identifier]

        // ⌘K opens the list in a popover, a window of its own, so its rows are looked up from
        // the app rather than the panel. The list starts on Paste; ↓ walks down to Delete, the
        // last row. Keys only, no clicks: a click would make Yank the active app, which the
        // panel is built to work without.
        app.typeKey("k", modifierFlags: .command)
        let actions = app.descendants(matching: .any).matching(identifier: "actions").firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        let rows = actions.outlineRows
        for _ in 1..<rows.count { app.typeKey(.downArrow, modifierFlags: []) }
        // Stop if the highlight is anywhere else: Return on another row could paste into
        // whatever app is in front.
        guard rows.containing(.button, identifier: "action-delete").firstMatch.isSelected else {
            return XCTFail("↓ did not move the highlight to Delete")
        }
        // Return runs the highlighted row, which asks first; Return again confirms.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["delete-items"].waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(firstCard.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testShiftArrowSelectsTwoCards() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed", "20", "--show-panel"]
        app.launch()
        XCTAssertTrue(app.textFields["search"].waitForExistence(timeout: 5))
        let cards = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'card-'"))
        XCTAssertTrue(cards.element(boundBy: 1).waitForExistence(timeout: 5))

        // The first card starts selected; ⇧→ adds the second without dropping the first.
        app.typeKey(.rightArrow, modifierFlags: .shift)
        XCTAssertTrue(cards.element(boundBy: 0).isSelected)
        XCTAssertTrue(cards.element(boundBy: 1).isSelected)
        XCTAssertFalse(cards.element(boundBy: 2).isSelected)

        // ⌫ with the search box empty asks before deleting both; Esc keeps them.
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Delete 2 items?"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["delete-items"].waitForNonExistence(timeout: 5))

        // A plain → collapses to one card again: the one after the lead card (the second, the
        // one ⇧→ moved to), so the third, as in Finder.
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertFalse(cards.element(boundBy: 0).isSelected)
        XCTAssertFalse(cards.element(boundBy: 1).isSelected)
        XCTAssertTrue(cards.element(boundBy: 2).isSelected)
    }
}
