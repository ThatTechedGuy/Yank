// The editor as a user meets it: ⌘N from the panel opens an empty editor, typing and Save as
// New puts a card with those words at the front of the history; ⌘E on a card opens that card
// with Replace Original on offer, and Cancel closes it without a change; the editor passes
// Apple's accessibility audit. Launched with a fake history, like PanelTests. (See LaunchTests for what XCTest and XCUIApplication are.)
import XCTest

final class EditorTests: XCTestCase {
    @MainActor
    func testNewTextItemBecomesACard() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed", "20", "--show-panel"]
        app.launch()
        XCTAssertTrue(app.textFields["search"].waitForExistence(timeout: 5))
        let cards = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'card-'"))
        let front = cards.element(boundBy: 0)
        XCTAssertTrue(front.waitForExistence(timeout: 5))
        let oldFrontId = front.identifier

        // ⌘N: the panel goes, an editor window with an empty text box comes, with the cursor
        // already in the box (the window puts it there), so the words are typed straight in.
        app.typeKey("n", modifierFlags: .command)
        let text = app.textViews["editor-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        app.typeText("Typed in the editor")
        app.buttons["save-new"].click()

        // The editor closes and the panel is back with a new card in front of the old one,
        // selected. A card is one element with no text of its own to the accessibility tree,
        // so Space opens its preview, whose counts say what was saved: "Typed in the editor"
        // is 19 characters and 4 words.
        XCTAssertTrue(text.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.textFields["search"].waitForExistence(timeout: 5))
        let newFront = expectation(
            for: NSPredicate(format: "identifier != %@", oldFrontId), evaluatedWith: front)
        wait(for: [newFront], timeout: 5)
        XCTAssertTrue(front.isSelected)
        app.typeKey(.space, modifierFlags: [])
        let detail = app.staticTexts["preview-detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertEqual(detail.value as? String ?? detail.label, "19 characters · 4 words")
    }

    @MainActor
    func testEditOpensTheCardAndCancelChangesNothing() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed", "20", "--show-panel"]
        app.launch()
        XCTAssertTrue(app.textFields["search"].waitForExistence(timeout: 5))
        let cards = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'card-'"))
        let front = cards.element(boundBy: 0)
        XCTAssertTrue(front.waitForExistence(timeout: 5))
        let frontId = front.identifier
        let count = cards.count

        // ⌘E on the selected card: an editor with Replace Original on offer (a card from the
        // fake history is text or an image, both editable). Cancel closes it.
        app.typeKey("e", modifierFlags: .command)
        let cancel = app.buttons["cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["replace"].exists)
        cancel.click()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))

        // Nothing was saved: the panel, reopened from the menu bar, has the same card in front
        // and as many cards as before.
        app.statusItems.firstMatch.click()
        app.menuItems["Open Panel"].click()
        XCTAssertTrue(front.waitForExistence(timeout: 5))
        XCTAssertEqual(front.identifier, frontId)
        XCTAssertEqual(cards.count, count)
    }

    @MainActor
    func testTheEditorPassesTheAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--seed", "20", "--show-panel"]
        app.launch()
        XCTAssertTrue(app.textFields["search"].waitForExistence(timeout: 5))

        // ⌘N opens the editor for a new text item; the audit (see AccessibilityAudit.swift) runs on it.
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textViews["editor-text"].waitForExistence(timeout: 5))
        try app.auditAccessibility()
        app.buttons["cancel"].click()
    }
}
