// The app's global keyboard shortcuts. The KeyboardShortcuts package registers them with macOS and
// remembers the user's own choice.
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Shows the panel if hidden, hides it if showing. ⇧⌘V unless the user records another key.
    static let togglePanel = Self("togglePanel", initial: .init(.v, modifiers: [.shift, .command]))
    /// Pastes the oldest item waiting in the paste stack. ⌃⌥⌘V: ⇧⌘V is the panel, and
    /// ⌥⇧⌘V already means "Paste and Match Style" in Apple's apps.
    static let pasteNext = Self("pasteNext", initial: .init(.v, modifiers: [.control, .option, .command]))
    /// Turns the paste stack on or off. No default key; the menu bar does it, and the user can
    /// record a key in Settings.
    static let toggleStack = Self("toggleStack")
}
