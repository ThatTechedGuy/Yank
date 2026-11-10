import AppKit
import ClipCore
import Sauce

// A key event carries a key code, which names a physical key, not a letter: code 9 is V on a US
// keyboard but "." on Dvorak. So Sauce looks up the key that types "v" while ⌘ is held; layouts
// such as "Dvorak – QWERTY ⌘" switch to QWERTY positions while ⌘ is down.
/// `CGEvent` as a `KeyPressing`: presses ⌘V on the user's own keyboard layout.
@MainActor public final class KeyPresser: KeyPressing {
    public init() {}

    public func pressPaste() throws {
        guard let keyCode = Self.pasteKeyCode() else { throw KeyPressError.noKeyTypesV }
        // One event source for both halves, so the system sees a press and a release that
        // belong together.
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { throw KeyPressError.eventNotCreated }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // Without the Accessibility permission these calls silently do nothing, which is why
        // PasteService checks the permission first.
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// The key code that types "v" while ⌘ is held on `layout`, or on the user's current layout
    /// when nil; nil if no key does (some input methods, such as Japanese, have no key table).
    /// `internal` so the tests can run it over layouts other than the current one.
    static func pasteKeyCode(on layout: InputSource? = nil) -> CGKeyCode? {
        let paste = (key: Key.v, modifiers: SauceModifiers.cocoa(.command))
        guard let layout else {
            return Sauce.shared.currentKeyCode(for: paste.key, modifiers: paste.modifiers)
        }
        return Sauce.shared.keyCode(with: layout, key: paste.key, modifiers: paste.modifiers)
    }
}

/// Why ⌘V could not be sent.
public enum KeyPressError: Error {
    /// The current keyboard layout has no key that types "v" with ⌘ held.
    case noKeyTypesV
    /// macOS refused to create the keyboard event.
    case eventNotCreated
}
