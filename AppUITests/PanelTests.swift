// The app is launched with a fake history (`--seed`), so these tests never depend on, or touch,
// what this Mac has really copied. The paste test writes to the real clipboard.
import XCTest

final class PanelTests: XCTestCase {
    @MainActor
    func testPanelOpensFocusedOnSearchAndArrowKeysMoveSelection() {
        let app = XCUIApplication()
        // `--show-panel` because the global ⇧⌘V shortcut is unreliable from a test: macOS may
        // deliver it to another app that uses the same key.
        app.launchArguments = ["--seed", "20", "--show-panel"]
        app.launch()

        let search = app.textFields["search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.value(forKey: "hasKeyboardFocus") as? Bool ?? false)

        // Card ids keep growing across seedings, so take the first two in row order instead of
        // guessing ids. A card is one piece of text to the accessibility tree, hence
        // `staticTexts`.
        let cards = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'card-'"))
        let first = cards.element(boundBy: 0)
        let second = cards.element(boundBy: 1)
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertTrue(first.isSelected)
        XCTAssertFalse(second.isSelected)

        // The arrows move the selection even though the cursor is in search.
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(second.isSelected)
        XCTAssertFalse(first.isSelected)
        app.typeKey(.leftArrow, modifierFlags: [])
        XCTAssertTrue(first.isSelected)

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
    }

    /// The app is told to paste "to clipboard only", so the test never presses ⌘V into whatever
    /// app is behind it. The clipboard is checked by its change counter and its list of types,
    /// not its contents: reading the contents from the test process would trip macOS's "paste
    /// from other apps" prompt.
    @MainActor
    func testReturnAndCommandDigitPasteACardToTheClipboard() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed", "20", "--show-panel", "-pasteDestination", "clipboardOnly"]
        app.launch()
        let search = app.textFields["search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))

        // The selected (newest) card is a text item. Yank's own marker keeps the capture loop
        // from saving the paste again.
        let pasteboard = NSPasteboard.general
        var before = pasteboard.changeCount
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        XCTAssertGreaterThan(pasteboard.changeCount, before)
        var types = (pasteboard.types ?? []).map(\.rawValue)
        XCTAssertTrue(types.contains("public.utf8-plain-text"), "\(types)")
        XCTAssertTrue(types.contains("com.thattechedguy.yank.own-paste"), "\(types)")

        // The seed makes the second card a link.
        app.launch()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        before = pasteboard.changeCount
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        XCTAssertGreaterThan(pasteboard.changeCount, before)
        types = (pasteboard.types ?? []).map(\.rawValue)
        XCTAssertTrue(types.contains("public.url"), "\(types)")
    }

    @MainActor
    func testTypingFiltersTheCardsAndClearingRestoresThem() {
        let app = XCUIApplication()
        // Of twenty fake items, three are files named "report-<n>.pdf" and four were copied from
        // Safari.
        app.launchArguments = ["--seed", "20", "--show-panel"]
        app.launch()
        let search = app.textFields["search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        // The row only builds the cards that fit on screen (about ten), so the count is never
        // exactly twenty.
        let cards = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'card-'"))
        XCTAssertTrue(cards.element(boundBy: 5).waitForExistence(timeout: 5))

        search.typeText("report")
        XCTAssertTrue(waitUntil { cards.count == 3 })
        XCTAssertTrue(cards.element(boundBy: 0).isSelected)

        // The app's name counts too: "safari" is in no card's text.
        search.typeKey("a", modifierFlags: .command)
        search.typeText("safari")
        XCTAssertTrue(waitUntil { cards.count == 4 })

        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(waitUntil { cards.count > 5 })
    }

    @MainActor
    func testSpaceShowsTheSelectedCardsPreviewAndEscClosesIt() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed", "20", "--show-panel"]
        app.launch()
        let search = app.textFields["search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        let cards = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'card-'"))
        XCTAssertTrue(cards.element(boundBy: 0).waitForExistence(timeout: 5))

        // The newest fake item is a text of 46 characters and 9 words. The search box is empty,
        // so the Space is not typed into it.
        app.typeKey(.space, modifierFlags: [])
        let detail = app.staticTexts["preview-detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertEqual(detail.value as? String ?? detail.label, "46 characters · 9 words")
        XCTAssertEqual(search.value as? String, "")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(detail.waitForNonExistence(timeout: 5))
        XCTAssertTrue(search.exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testCardsReadAsOneSentenceAndThePanelPassesTheAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--seed", "20", "--show-panel"]
        app.launch()
        let cards = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'card-'"))
        let first = cards.element(boundBy: 0)
        XCTAssertTrue(first.waitForExistence(timeout: 5))

        // What VoiceOver reads for the newest fake item. The middle of the sentence is the
        // card's age, which depends on the clock, so only the two ends are checked.
        let spoken = first.value as? String ?? ""
        XCTAssertTrue(spoken.hasPrefix("Card 1 of 20. Text from Safari, "), spoken)
        XCTAssertTrue(spoken.hasSuffix(": Sample item 0: meeting moved to 3 pm Thursday."), spoken)

        try app.auditAccessibility()
    }

    /// Polls `condition` for up to five seconds: the search runs in the background, so an
    /// assert right after typing is too early.
    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
