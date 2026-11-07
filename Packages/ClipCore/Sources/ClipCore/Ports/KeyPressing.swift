// A port (≈ a TS interface) for the one key the app ever presses on the user's behalf: ⌘V in
// the app they were working in, so a paste from the panel lands where their cursor is. The
// core only knows "press paste"; ClipSystem's KeyPresser does it with a synthetic keyboard
// event, and tests use a fake that counts the presses, because a test must never type ⌘V into
// whatever app happens to be open on the Mac running it.
//
// `@MainActor`, like `Clipboard`: the real version asks macOS for the current keyboard layout,
// which must happen on the main thread.

/// Presses ⌘V in the app in front.
@MainActor public protocol KeyPressing: AnyObject {
    /// Presses and releases ⌘V. Throws when the key could not be sent, for example when the
    /// keyboard layout has no key that types "v".
    func pressPaste() throws
}
