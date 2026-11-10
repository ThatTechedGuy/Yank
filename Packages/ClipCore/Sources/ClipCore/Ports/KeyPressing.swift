// A port so tests count presses instead of typing ⌘V into whatever app is open on the Mac running
// them. Main-actor because the real one reads the current keyboard layout, which must happen on
// the main thread.

/// Presses ⌘V in the app in front.
@MainActor public protocol KeyPressing: AnyObject {
    /// Presses and releases ⌘V. Throws when the key could not be sent, for example when the
    /// keyboard layout has no key that types "v".
    func pressPaste() throws
}
