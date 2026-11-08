// The menu and the Settings window as a user meets them: Pause Saving flips the menu to
// "Paused" and Resume flips it back; a setting changed in the window is still set after a
// relaunch; cancelling "Erase History…" keeps the history; every tab passes Apple's
// accessibility audit. (See LaunchTests for what XCTest and XCUIApplication are.)
//
// These tests drive the real Settings window, so they write to the real UserDefaults of the
// app on this Mac. Each one puts back what it changed before it ends.
import XCTest

final class SettingsTests: XCTestCase {
    @MainActor
    func testPauseSavingShowsPausedInTheMenuAndResumeClearsIt() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed", "20"]
        app.launch()
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))

        // Pause Saving › Until Resumed. Clicking a submenu's title opens it; its rows are then
        // ordinary menu items.
        statusItem.click()
        let pauseMenu = app.menuItems["Pause Saving"]
        XCTAssertTrue(pauseMenu.waitForExistence(timeout: 5))
        pauseMenu.click()
        let untilResumed = app.menuItems["Until Resumed"]
        XCTAssertTrue(untilResumed.waitForExistence(timeout: 5))
        untilResumed.click()
        XCTAssertTrue(pauseMenu.waitForNonExistence(timeout: 5))

        // The menu now says Paused and offers Resume instead of Pause.
        statusItem.click()
        let resume = app.menuItems["Resume Saving"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Paused"].exists)
        XCTAssertFalse(app.menuItems["Pause Saving"].exists)
        resume.click()
        XCTAssertTrue(resume.waitForNonExistence(timeout: 5))

        // And back to Pause Saving after Resume.
        statusItem.click()
        XCTAssertTrue(app.menuItems["Pause Saving"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["Resume Saving"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testPlainTextSettingSurvivesARelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed", "20"]
        app.launch()
        // The window reopens on the tab it was last on, so pick General each time.
        let settings = openSettings(app)
        settings.toolbars.buttons["General"].click()
        // In a grouped Form a Toggle is a switch with no label of its own, so it is found by id.
        let plainText = settings.switches["always-plain-text"]
        XCTAssertTrue(plainText.waitForExistence(timeout: 5))
        let before = plainText.value as? Int
        plainText.click()
        XCTAssertNotEqual(plainText.value as? Int, before)

        // A fresh launch reads the setting back from disk.
        app.launch()
        let reopened = openSettings(app)
        reopened.toolbars.buttons["General"].click()
        let afterRelaunch = reopened.switches["always-plain-text"]
        XCTAssertTrue(afterRelaunch.waitForExistence(timeout: 5))
        XCTAssertNotEqual(afterRelaunch.value as? Int, before)
        // Put the user's own choice back.
        afterRelaunch.click()
        XCTAssertEqual(afterRelaunch.value as? Int, before)
    }

    @MainActor
    func testCancellingEraseHistoryKeepsTheItems() {
        let app = XCUIApplication()
        app.launchArguments = ["--seed", "20"]
        app.launch()
        let settings = openSettings(app)
        settings.toolbars.buttons["Data"].click()

        // The Data tab shows the same count as the menu. Match its shape, not the number: the
        // seeded database may hold more than the twenty fake items.
        let count = settings.staticTexts.matching(NSPredicate(format: "value MATCHES '[0-9]+ items? saved'"))
            .firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let countBefore = count.value as? String

        // Erase History… asks first; Cancel changes nothing.
        settings.buttons["erase-history"].click()
        let cancel = settings.sheets.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertEqual(count.value as? String, countBefore)
    }

    @MainActor
    func testEverySettingsTabPassesTheAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--seed", "20"]
        app.launch()
        let settings = openSettings(app)
        // Each tab shows different controls, so each gets its own audit (see AccessibilityAudit.swift).
        for tab in ["General", "Privacy", "Data"] {
            settings.toolbars.buttons[tab].click()
            // The window is titled after the open tab; checking it makes sure the audit below
            // looks at the tab it names, not the one before.
            XCTAssertEqual(settings.title, tab)
            try app.auditAccessibility()
        }
    }

    /// Opens Settings from the menu bar menu and returns its window. Settings is a SwiftUI
    /// scene, so the window's title is the selected tab's name; the toolbar with the three tab
    /// buttons is what identifies it.
    @MainActor
    private func openSettings(_ app: XCUIApplication) -> XCUIElement {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        // Scoped to the status item's menu: the app's hidden main menu has a "Settings…" too.
        let settingsRow = statusItem.menuItems["Settings…"]
        XCTAssertTrue(settingsRow.waitForExistence(timeout: 5))
        settingsRow.click()
        let window = app.windows.containing(.toolbar, identifier: nil).firstMatch
        XCTAssertTrue(window.toolbars.buttons["General"].waitForExistence(timeout: 5))
        return window
    }
}
