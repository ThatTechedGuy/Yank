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

        // The editor window puts the cursor in its text box, so the words are typed straight in.
        app.typeKey("n", modifierFlags: .command)
        let text = app.textViews["editor-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        app.typeText("Typed in the editor")
        app.buttons["save-new"].click()

        // Space opens the new card's preview, whose counts say what was saved: "Typed in the
        // editor" is 19 characters and 4 words.
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

        // The front card of the fake history is a text, so Replace Original is on offer.
        app.typeKey("e", modifierFlags: .command)
        let cancel = app.buttons["cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["replace"].exists)
        cancel.click()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))

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

        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textViews["editor-text"].waitForExistence(timeout: 5))
        try app.auditAccessibility()
        app.buttons["cancel"].click()
    }
}
