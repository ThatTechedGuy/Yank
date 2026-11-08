import Carbon.HIToolbox
import Sauce
import Testing

@testable import ClipSystem

// Proves the paste key is looked up on the keyboard layout, not hard-coded: on Dvorak the key
// that types "v" sits where QWERTY has ".", so a fixed key code would paste nothing and type a
// stray character. Runs against the real layouts macOS ships, without pressing anything.
@MainActor struct KeyPresserTests {
    /// A keyboard layout by its macOS id, whether or not the user has it enabled.
    /// (`TISCreateInputSourceList` with `true` lists every installed source.)
    func installed(_ id: String) throws -> TISInputSource {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        let list = TISCreateInputSourceList(filter, true).takeRetainedValue() as! [TISInputSource]
        return try #require(list.first)
    }

    func isEnabled(_ source: TISInputSource) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled) else {
            return false
        }
        return Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue() == kCFBooleanTrue
    }

    @Test func theVKeyIsFoundOnEachLayout() throws {
        // Sauce only knows the layouts in the user's input menu, so the ones this test needs are
        // added to that menu for the test and removed again after, unless they were already there.
        // They are added, not selected: what the user types does not change. Sauce reads the
        // menu when it is first used, which is below, so the test must not touch it before this.
        let ids = [
            "com.apple.keylayout.US", "com.apple.keylayout.Dvorak", "com.apple.keylayout.DVORAK-QWERTYCMD",
        ]
        let added = try ids.map(installed).filter { !isEnabled($0) }
        for source in added { TISEnableInputSource(source) }
        defer { for source in added { TISDisableInputSource(source) } }
        func layout(_ id: String) throws -> InputSource {
            try #require(Sauce.shared.currentInputSources().first { $0.id == id })
        }
        // Key code 9 is the QWERTY V key; 47 is the QWERTY "." key, which types "v" on Dvorak.
        // "Dvorak – QWERTY ⌘" types Dvorak but uses QWERTY positions while ⌘ is held, so its
        // ⌘V is on the QWERTY key: that is why the lookup holds ⌘ down.
        #expect(KeyPresser.pasteKeyCode(on: try layout(ids[0])) == 9)
        #expect(KeyPresser.pasteKeyCode(on: try layout(ids[1])) == 47)
        #expect(KeyPresser.pasteKeyCode(on: try layout(ids[2])) == 9)
    }
}
