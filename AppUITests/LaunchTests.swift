// The one end-to-end check: the real, signed, sandboxed Yank.app launches, puts its icon in the menu
// bar and shows the saved count. Package tests cannot prove that, because they never build the app.
//
// XCTest is Apple's older test framework. We still use it for UI tests, because XCUIApplication
// (the API that launches an app and drives it like a user) only exists in XCTest.
// ≈ Espresso or Detox for Android/RN, or Playwright for the web.
import XCTest

// UI tests subclass XCTestCase, JUnit 4 style. Any method whose name starts with `test` runs.
// `final` means no other class may subclass this one (≈ a Kotlin class, which is final by default).
final class LaunchTests: XCTestCase {
    // XCUIApplication must be used on the main thread, so the method is marked @MainActor.
    // (Unlike the app target, test targets don't default to the main thread.)
    @MainActor
    func testAppLaunchesWithMenuBarIcon() {
        // XCUIApplication() refers to the app under test: Yank, set by TEST_TARGET_NAME in
        // project.yml, built as Debug, so "Yank Debug" with bundle id com.thattechedguy.Yank.debug
        // and its own history and settings. launch() starts a fresh copy of it, quitting any copy
        // a previous test left; the Release copy in /Applications is a different app and stays.
        let app = XCUIApplication()
        app.launch()

        // Yank has no windows, only a menu bar item ("status item" in AppKit terms), so its icon
        // appearing is the proof that the app launched. waitForExistence polls the accessibility
        // tree for up to 5 s, ≈ Detox's waitFor(...), because launch takes a moment.
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))

        // Open the menu and check the count row is there: it proves the database opened, since the
        // error row replaces it otherwise. The number depends on what this Mac has saved, so match
        // the shape only: a number, then "item" or "items", then "saved". `MATCHES` takes a regular
        // expression; it is NSPredicate syntax, Apple's query mini-language (≈ a SQL WHERE clause
        // for objects).
        statusItem.click()
        let countRow = app.menuItems.matching(NSPredicate(format: "title MATCHES '[0-9]+ items? saved'"))
        XCTAssertTrue(countRow.firstMatch.waitForExistence(timeout: 5))
        // Close the menu again so the next test starts clean. ⎋ = Escape.
        app.typeKey(.escape, modifierFlags: [])
    }
}
