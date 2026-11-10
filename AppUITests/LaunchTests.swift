// The one end-to-end check that the real, signed, sandboxed Yank.app launches. Package tests
// cannot prove that, because they never build the app.
import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testAppLaunchesWithMenuBarIcon() {
        // The app under test is the Debug build, "Yank Debug" (com.thattechedguy.Yank.debug),
        // with its own history and settings. The Release copy in /Applications is a different
        // app, which launch() does not quit.
        let app = XCUIApplication()
        app.launch()

        // Yank has no windows, so its menu bar icon appearing is the proof that it launched.
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))

        // The count row proves the database opened: the error row replaces it otherwise. The
        // number depends on what this Mac has saved, so match the shape only.
        statusItem.click()
        let countRow = app.menuItems.matching(NSPredicate(format: "title MATCHES '[0-9]+ items? saved'"))
        XCTAssertTrue(countRow.firstMatch.waitForExistence(timeout: 5))
        // Close the menu so the next test starts clean.
        app.typeKey(.escape, modifierFlags: [])
    }
}
