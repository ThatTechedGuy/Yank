import Carbon.HIToolbox
import Testing

@testable import ClipSystem

// Proves the paste key is looked up on the keyboard layout, not hard-coded: on Dvorak the key
// that types "v" sits where QWERTY has ".", so a fixed key code would paste nothing and type a
// stray character. Runs against the real layouts macOS ships, without changing the user's
// current layout and without pressing anything.
@MainActor struct KeyPresserTests {
    /// A keyboard layout by its macOS id, whether or not the user has it enabled.
    /// (`TISCreateInputSourceList` with `true` lists every installed source.)
    func layout(_ id: String) throws -> TISInputSource {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        let list = TISCreateInputSourceList(filter, true).takeRetainedValue() as! [TISInputSource]
        return try #require(list.first)
    }

    @Test func theVKeyIsFoundOnEachLayout() throws {
        // Key code 9 is the QWERTY V key; 47 is the QWERTY "." key, which types "v" on Dvorak.
        // "Dvorak – QWERTY ⌘" types Dvorak but uses QWERTY positions while ⌘ is held, so its
        // ⌘V is on the QWERTY key: that is why the lookup holds ⌘ down.
        #expect(KeyPresser.keyCode(typing: "v", withCommandOn: try layout("com.apple.keylayout.US")) == 9)
        #expect(
            KeyPresser.keyCode(typing: "v", withCommandOn: try layout("com.apple.keylayout.Dvorak")) == 47)
        #expect(
            KeyPresser.keyCode(typing: "v", withCommandOn: try layout("com.apple.keylayout.DVORAK-QWERTYCMD"))
                == 9)
    }
}
