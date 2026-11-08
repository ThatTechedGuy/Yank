// The app's global keyboard shortcuts, each with a name and a default key. Global means they
// work from any app, like Spotlight's ⌘Space, not only while Yank is in front; the
// KeyboardShortcuts package registers them with macOS and remembers the user's own choice
// (a Settings screen can offer a "record shortcut" box for each name later). Defining them in
// one place means the name string is typed once.
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Shows the panel if hidden, hides it if showing. ⇧⌘V, the same key as Paste.app, so
    /// quit Paste while trying Yank or they fight over it.
    static let togglePanel = Self("togglePanel", initial: .init(.v, modifiers: [.shift, .command]))
    /// Pastes the oldest item waiting in the paste stack. ⌃⌥⌘V: ⇧⌘V is the panel, and
    /// ⌥⇧⌘V already means "Paste and Match Style" in Apple's apps.
    static let pasteNext = Self("pasteNext", initial: .init(.v, modifiers: [.control, .option, .command]))
    /// Turns the paste stack on or off. No default key; the menu bar does it, and the user can
    /// record a key in Settings.
    static let toggleStack = Self("toggleStack")
}
