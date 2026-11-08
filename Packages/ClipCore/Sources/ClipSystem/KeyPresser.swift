// CoreGraphics (part of AppKit's imports) is where synthetic keyboard events live. Sauce is the
// Clipy project's small library that knows, for each keyboard layout, which physical key types
// which letter; Maccy and Clipy use it for exactly this job.
import AppKit
import ClipCore
import Sauce

// Presses ⌘V in the app in front, behind ClipCore's `KeyPressing` port. macOS has no "paste
// into that app" call; what we can do, with the Accessibility permission, is post a keyboard
// event to the system as if the user had pressed the key (≈ Android's
// `Instrumentation.sendKeyDownUpSync`, or `xdotool key` on Linux). The app in front receives it
// like any keystroke and pastes.
//
// The catch: a keyboard event carries a *key code*, which names a physical key, not a letter.
// Key code 9 is the key labelled V on a US keyboard, but on Dvorak that same key types ".", so
// posting 9 there would send ⌘. instead of ⌘V. So before pressing, we ask Sauce which key types
// "v" on the current layout while ⌘ is held. "While ⌘ is held" matters for layouts such as
// "Dvorak – QWERTY ⌘", which type Dvorak but switch to QWERTY positions while ⌘ is down: there,
// the key for ⌘V is the QWERTY one. Sauce reads the layout's key table once per layout and
// caches it, and listens for the user switching layouts, so the lookup is a dictionary read.
/// `CGEvent` as a `KeyPressing`: presses ⌘V on the user's own keyboard layout.
@MainActor public final class KeyPresser: KeyPressing {
    public init() {}

    public func pressPaste() throws {
        guard let keyCode = Self.pasteKeyCode() else { throw KeyPressError.noKeyTypesV }
        // One event source for both halves, so the system sees a press and a release that
        // belong together. `.combinedSessionState` means "a keyboard in the user's session".
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { throw KeyPressError.eventNotCreated }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // `.cghidEventTap` posts at the lowest level, where real keyboards come in, so every app
        // treats it as a real key. Without the Accessibility permission these calls silently do
        // nothing, which is why PasteService checks the permission first.
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
