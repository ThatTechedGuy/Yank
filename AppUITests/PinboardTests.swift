import XCTest

final class PinboardTests: XCTestCase {
    @MainActor
    func testPinningMovesTheCardToThePinboardsTab() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed", "20", "--show-panel"]
        app.launch()
        let search = app.textFields["search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        // Looked up by its "card-<id>" name, so it can be found again on the other tab.
        let cards = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'card-'"))
        let first = cards.element(boundBy: 0)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let firstCard = app.staticTexts[first.identifier]

        // ⌘P with no pinboard yet opens the name prompt with the cursor in its box. Return
        // creates the pinboard, pins the selected card to it and switches to its tab. Keys
        // only: XCTest makes Yank the active app before it clicks anything, and the panel is
        // built to work while Yank is not active.
        app.typeKey("p", modifierFlags: .command)
        let name = app.textFields["pinboard-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        app.typeText("Snippets\r")
        let snippetsTab = app.buttons["Snippets"]
        XCTAssertTrue(snippetsTab.waitForExistence(timeout: 5))
        XCTAssertTrue(firstCard.waitForExistence(timeout: 5))
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(firstCard.isSelected)

        // ⌘[ goes one tab left, back to History.
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(firstCard.waitForNonExistence(timeout: 5))
        XCTAssertGreaterThan(cards.count, 1)

        // ⌘P on a pinned card unpins it.
        app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(firstCard.waitForExistence(timeout: 5))
        app.typeKey("p", modifierFlags: .command)
        XCTAssertTrue(firstCard.waitForNonExistence(timeout: 5))
    }
}
