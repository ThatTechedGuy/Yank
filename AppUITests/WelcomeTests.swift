// The welcome window as a new user meets it: it opens by itself on the first launch, with the
// panel shortcut, the Accessibility status and the open-at-login switch, it passes Apple's
// accessibility audit, and it never opens again on a later launch. (See LaunchTests for what
// XCTest and XCUIApplication are.)
//
// "First launch" is faked with `-hasShownWelcome NO` on the command line: macOS lets a launch
// argument of the form `-key value` stand in for a saved setting for that one run, so this
// launch behaves like the first one while the real setting is left alone. The window itself
// then saves "shown" for good, which is what the second launch checks. That saved value belongs
// to the Debug build ("Yank Debug"), which has its own settings, so the Release copy in
// /Applications still shows its welcome window on its own first launch.
import XCTest

final class WelcomeTests: XCTestCase {
    @MainActor
    func testWelcomeWindowShowsOnFirstLaunchOnly() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--seed", "20", "-hasShownWelcome", "NO"]
        app.launch()

        // The window is up with its three rows: the shortcut box, the permission status and the
        // login switch (a switch in a grouped form is found by its id, as in SettingsTests).
        let getStarted = app.buttons["get-started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Show panel"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["accessibility-status"].exists)
        XCTAssertTrue(app.switches["open-at-login"].exists)
        try app.auditAccessibility()

        // Get Started closes it.
        getStarted.click()
        XCTAssertTrue(getStarted.waitForNonExistence(timeout: 5))

        // A later launch, with no flag: the first launch saved "shown", so the app starts with
        // only its menu bar icon.
        app.launchArguments = ["--seed", "20"]
        app.launch()
        XCTAssertTrue(app.statusItems.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(getStarted.waitForExistence(timeout: 2))
    }
}
