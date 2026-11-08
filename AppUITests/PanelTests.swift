// The panel as a user meets it: it opens with the cursor in search, the arrow keys move the
// selection, Return and ⌘1–⌘9 paste, Space shows the selected card's preview, and Esc closes
// it; each card reads as one sentence to VoiceOver, and the panel passes Apple's accessibility
// audit. The app is launched with a fake history so the test never depends on, or touches, what
// this Mac has really copied. (See LaunchTests for what XCTest and XCUIApplication are.)
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

    /// Return and ⌘2 put a card on the clipboard and close the panel. The app is told to paste
    /// "to clipboard only", so the test never presses ⌘V into whatever app is behind it. The
    /// clipboard is checked by its change counter and its list of types, not its contents:
    /// reading the contents from the test process would trip macOS's "paste from other apps"
    /// prompt.
    @MainActor
    func testReturnAndCommandDigitPasteACardToTheClipboard() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed", "20", "--show-panel", "-pasteDestination", "clipboardOnly"]
        app.launch()
        let search = app.textFields["search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))

        // Return pastes the selected (newest) card, a text item, with Yank's own marker so the
        // capture loop does not save it again. The panel closes.
        let pasteboard = NSPasteboard.general
        var before = pasteboard.changeCount
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        XCTAssertGreaterThan(pasteboard.changeCount, before)
        var types = (pasteboard.types ?? []).map(\.rawValue)
        XCTAssertTrue(types.contains("public.utf8-plain-text"), "\(types)")
        XCTAssertTrue(types.contains("com.thattechedguy.yank.own-paste"), "\(types)")

        // ⌘2 pastes the second card, which the seed makes a link, not the selected one.
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
        // Twenty fake items: every eighth is a file named "report-<n>.pdf" (three of them),
        // and every sixth was copied from "Safari" (four of them).
        app.launchArguments = ["--seed", "20", "--show-panel"]
        app.launch()
        let search = app.textFields["search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        // The row only builds the cards that fit on screen (about ten), so the full list is
        // "more than a handful", never exactly twenty.
        let cards = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'card-'"))
        XCTAssertTrue(cards.element(boundBy: 5).waitForExistence(timeout: 5))

        // Typing a word keeps only the cards that contain it, and selects the first of them.
        search.typeText("report")
        XCTAssertTrue(waitUntil { cards.count == 3 })
        XCTAssertTrue(cards.element(boundBy: 0).isSelected)

        // The app's name counts too, so "safari" finds what was copied from Safari even though
        // the word is not in the text. (A partial word does as well: "saf" would find the same.)
        search.typeKey("a", modifierFlags: .command)
        search.typeText("safari")
        XCTAssertTrue(waitUntil { cards.count == 4 })

        // Clearing the box brings the whole history back.
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

        // The newest fake item is a text, so Space opens the large preview with its counts
        // ("Sample item 0: meeting moved to 3 pm Thursday." is 46 characters, 9 words). The
        // search box is empty, so the Space is not typed into it.
        app.typeKey(.space, modifierFlags: [])
        let detail = app.staticTexts["preview-detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        XCTAssertEqual(detail.value as? String ?? detail.label, "46 characters · 9 words")
        XCTAssertEqual(search.value as? String, "")

        // Esc closes the preview and keeps the panel; a second Esc hides the panel.
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

        // What VoiceOver reads for the newest fake item, a text copied from Safari a moment ago:
        // its place in the row, its kind and app, its age (the middle, which depends on the
        // clock, is not checked) and its words. A card is one piece of text to the
        // accessibility tree, so the sentence is its `value`.
        let spoken = first.value as? String ?? ""
        XCTAssertTrue(spoken.hasPrefix("Card 1 of 20. Text from Safari, "), spoken)
        XCTAssertTrue(spoken.hasSuffix(": Sample item 0: meeting moved to 3 pm Thursday."), spoken)

        // Apple's accessibility audit (see AccessibilityAudit.swift for what it checks).
        try app.auditAccessibility()
    }

    /// Polls `condition` for up to five seconds. The cards change a moment after a keystroke
    /// (the search runs in the background), so a plain assert right after typing is too early.
    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
