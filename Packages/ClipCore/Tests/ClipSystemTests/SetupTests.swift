// Same framework as ClipCoreTests/SetupTests.swift; see the comments there.
// ClipSystem tests will run the real macOS adapters against safe stand-ins, such as a private,
// named clipboard instead of the one you use, so they never disturb your real data.
import Testing

@testable import ClipSystem

// Stage 0 placeholder: proves this test target builds and links ClipSystem.
struct SetupTests {
    // `Bool(true)` instead of plain `true`: #expect warns about conditions that are always true,
    // and wrapping it tells the compiler this is deliberate.
    @Test func moduleBuildsAndLinks() {
        #expect(Bool(true))
    }
}
