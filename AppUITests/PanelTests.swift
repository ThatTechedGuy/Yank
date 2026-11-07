// The panel as a user meets it: it opens with the cursor in search, the arrow keys move the
// selection, and Esc closes it. The app is launched with a fake history so the test never
// depends on, or touches, what this Mac has really copied. (See LaunchTests for what
// XCTest and XCUIApplication are.)
import XCTest

final class PanelTests: XCTestCase {
    @MainActor
    func testPanelOpensFocusedOnSearchAndArrowKeysMoveSelection() {
        let app = XCUIApplication()
        // Twenty fake items, and the panel already open: the global ⇧⌘V shortcut is not a
        // reliable way to open it from a test, because macOS may deliver it to another app that
        // uses the same key.
        app.launchArguments = ["--seed", "20", "--show-panel"]
        app.launch()

        // The panel is on screen with its search box, and the cursor is in it, so typing
        // searches at once. `hasKeyboardFocus` is the accessibility tree's word for "the cursor
        // is here".
        let search = app.textFields["search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.value(forKey: "hasKeyboardFocus") as? Bool ?? false)

        // The newest card starts selected. Cards are named "card-<id>" and the ids keep growing
        // across seedings, so take the first two in row order instead of guessing ids. (A card
        // is one piece of text to the accessibility tree, hence `staticTexts`.)
        let cards = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'card-'"))
        let first = cards.element(boundBy: 0)
        let second = cards.element(boundBy: 1)
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertTrue(first.isSelected)
        XCTAssertFalse(second.isSelected)

        // → moves the selection to the next card, even though the cursor is in search; ← back.
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(second.isSelected)
        XCTAssertFalse(first.isSelected)
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(first.isSelected)

        // Esc hides the panel.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
    }
}
