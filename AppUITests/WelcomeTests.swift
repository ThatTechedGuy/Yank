// `-hasShownWelcome NO` fakes a first launch for that one run without changing the saved
// setting. The window then saves "shown" to the Debug build's own settings, which is what the
// second launch checks.
import XCTest

final class WelcomeTests: XCTestCase {
    @MainActor
    func testWelcomeWindowShowsOnFirstLaunchOnly() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--seed", "20", "-hasShownWelcome", "NO"]
        app.launch()

        let getStarted = app.buttons["get-started"]
        XCTAssertTrue(getStarted.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Show panel"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["accessibility-status"].exists)
        XCTAssertTrue(app.switches["open-at-login"].exists)
        try app.auditAccessibility()

        getStarted.click()
        XCTAssertTrue(getStarted.waitForNonExistence(timeout: 5))

        // No flag this time: the first launch saved "shown".
        app.launchArguments = ["--seed", "20"]
        app.launch()
        XCTAssertTrue(app.statusItems.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(getStarted.waitForExistence(timeout: 2))
    }
}
