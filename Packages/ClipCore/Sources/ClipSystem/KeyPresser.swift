// Carbon is Apple's old C-level Mac toolbox. Most of it is gone, but Text Input Services (TIS),
// the part that knows which keyboard layout is active and what each key types, still lives
// there and has no newer replacement. CoreGraphics (part of AppKit's imports) is where
// synthetic keyboard events live.
import AppKit
import Carbon.HIToolbox
import ClipCore

// Presses ⌘V in the app in front, behind ClipCore's `KeyPressing` port. macOS has no "paste
// into that app" call; what we can do, with the Accessibility permission, is post a keyboard
// event to the system as if the user had pressed the key (≈ Android's
// `Instrumentation.sendKeyDownUpSync`, or `xdotool key` on Linux). The app in front receives it
// like any keystroke and pastes.
//
// The catch: a keyboard event carries a *key code*, which names a physical key, not a letter.
// Key code 9 is the key labelled V on a US keyboard, but on Dvorak that same key types ".", so
// posting 9 there would send ⌘. instead of ⌘V. So before pressing, we ask the current keyboard
// layout which key types "v" while ⌘ is held. "While ⌘ is held" matters for layouts such as
// "Dvorak – QWERTY ⌘", which type Dvorak but switch to QWERTY positions while ⌘ is down: there,
// the key for ⌘V is the QWERTY one.
/// `CGEvent` as a `KeyPressing`: presses ⌘V on the user's own keyboard layout.
@MainActor public final class KeyPresser: KeyPressing {
    public init() {}

    public func pressPaste() throws {
        guard let layout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let keyCode = Self.keyCode(typing: "v", withCommandOn: layout)
        else { throw KeyPressError.noKeyTypesV }
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

    /// The key code that types `character` while ⌘ is held, on `layout`, or nil if no key does.
    /// Tries every key code (there are at most 128) through the layout's own key table, the way
    /// macOS itself turns a key press into a character. `internal` so the integration tests can
    /// run it over layouts other than the current one.
    static func keyCode(typing character: Character, withCommandOn layout: TISInputSource) -> CGKeyCode? {
        // The layout's key table, as raw bytes in the format `UCKeyTranslate` reads. Some input
        // sources (Japanese and Chinese input methods, for example) have none; then there is
        // nothing to look up.
        guard let dataPointer = TISGetInputSourceProperty(layout, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue() as Data
        // `UCKeyTranslate` wants the modifier keys in the Carbon format: the ⌘ bit shifted down
        // one byte. (`cmdKey` is Carbon's name for that bit.)
        let commandDown = UInt32(cmdKey >> 8)
        return data.withUnsafeBytes { bytes -> CGKeyCode? in
            let table = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            for keyCode in 0..<128 as Range<UInt16> {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    table, keyCode, UInt16(kUCKeyActionDown), commandDown, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length,
                    &characters)
                guard status == noErr, length == 1,
                    String(utf16CodeUnits: characters, count: 1) == String(character)
                else { continue }
                return keyCode
            }
            return nil
        }
    }
}

/// Why ⌘V could not be sent.
public enum KeyPressError: Error {
    /// The current keyboard layout has no key that types "v" with ⌘ held.
    case noKeyTypesV
    /// macOS refused to create the keyboard event.
    case eventNotCreated
}
