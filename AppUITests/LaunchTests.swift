// XCTest is Apple's older test framework. We still use it for UI tests, because XCUIApplication
// (the API that launches an app and drives it like a user) only exists in XCTest.
// ≈ Espresso or Detox for Android/RN, or Playwright for the web.
import XCTest

// UI tests subclass XCTestCase, JUnit 4 style. Any method whose name starts with `test` runs.
// `final` means no other class may subclass this one (≈ a Kotlin class, which is final by default).
final class LaunchTests: XCTestCase {
    // XCUIApplication must be used on the main thread, so the method is marked @MainActor.
    // (Unlike the app target, test targets don't default to the main actor.)
    @MainActor
    func testAppLaunchesWithMenuBarIcon() {
        // XCUIApplication() refers to the app under test: Yank, set by TEST_TARGET_NAME in
        // project.yml. launch() starts a fresh copy of it.
        let app = XCUIApplication()
        app.launch()

        // Yank has no windows, only a menu bar item ("status item" in AppKit terms).
        // waitForExistence polls the accessibility tree for up to 5 s, ≈ Detox's waitFor(...).
        XCTAssertTrue(app.statusItems.firstMatch.waitForExistence(timeout: 5))
    }
}
