// Swift Testing is Apple's modern test framework (Xcode 16+). ≈ `bun test` / Jest / JUnit 5.
//   @Test   marks a test function, like `test("...", () => {...})` or JUnit's @Test.
//   #expect checks a condition and reports both sides on failure, like `expect(a).toBe(b)`.
// Run these with `swift test` inside Packages/ClipCore, or with scripts/test.sh.
import Testing

// `@testable import` also exposes the module's `internal` names to the test, so tests can reach
// things that aren't `public`. ≈ Kotlin's `internal` visibility being readable from module tests.
@testable import ClipCore

// A test suite is just a type holding @Test functions. `struct` is a value type (copied on
// assignment, like a number); Swift Testing creates a fresh instance for each test, so tests
// can't leak state into each other. ≈ a `describe(...)` block.
// Stage 0 placeholder: proves the test setup runs. Real tests replace it from stage 1.
struct SetupTests {
    // `func name() { ... }` declares a function. No `-> ReturnType` means it returns nothing.
    // Test names describe behaviour, per the plan's test rules.
    @Test func logsUseTheAppBundleID() {
        #expect(Log.subsystem == "com.thattechedguy.Yank")
    }
}
