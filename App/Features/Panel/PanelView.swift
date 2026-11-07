// What the panel shows: a search box on top (with a hint next to it when Yank may not press
// ⌘V) and the row of cards under it. It also owns the keyboard: where the cursor goes when the
// panel opens, what Tab, ← →, Return, ⌘1–⌘9 and Esc do. The window shell (PanelWindow) decides
// where on screen the panel is; this view decides what is in it. ≈ the screen component that a
// native container renders.
import ClipCore
import SwiftUI

struct PanelView: View {
    let model: PanelModel
    /// What Esc does. The window passes in "hide me", so this view never has to know about
    /// AppKit windows and can be previewed on its own.
    let dismiss: () -> Void

    /// The two places the keyboard focus can be. SwiftUI tracks focus with a `@FocusState`
    /// value: setting it moves the cursor, and clicking something sets it. ≈ a `ref.focus()`
    /// you can also read. `nil` means nothing in the panel has focus.
    private enum Focus { case search, cards }
    @FocusState private var focus: Focus?

    var body: some View {
        // `@Bindable` lets a text field write into an `@Observable` model: `$model.searchText`
        // is the two-way binding (≈ value + onChange in one).
        @Bindable var model = model
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // The search box. A plain `TextField`; searching is not wired up yet, it only
                // keeps the typed text.
                TextField("Search history…", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .search)
                    .accessibilityIdentifier("search")
                // One line next to search, only while Return cannot paste for the user. The
                // button opens macOS's own permission dialog; nothing else in the app ever
                // prompts. It sits in the top bar rather than above the cards so the panel
                // keeps its height and the cards their size.
                if model.needsAccessibility {
                    Text(
                        "Allow Yank in System Settings › Accessibility to paste for you. Until then, press ⌘V yourself."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    Button("Allow…") { model.requestAccessibility() }
                        .accessibilityIdentifier("allow-accessibility")
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            // A scrolling row cannot take keyboard focus on its own; `focusable()` lets Tab
            // land on it so typing stops going into the search box.
            CardRow(model: model)
                .focusable()
                .focused($focus, equals: .cards)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The frosted-glass look of system panels: what is behind shows through, blurred.
        .background(.regularMaterial)
        // Every time the panel opens, the cursor goes to search so the user can type at once.
        // `onChange` runs when the value flips, like a `useEffect` with `[isVisible]`.
        .onChange(of: model.isVisible, initial: true) { _, visible in
            if visible { focus = .search }
        }
        // Tab moves between search and the cards and back; SwiftUI would otherwise only move
        // it forward and then out of the panel. `.handled` means "I used this key, do not pass
        // it on".
        .onKeyPress(.tab) {
            focus = focus == .search ? .cards : .search
            return .handled
        }
        // ← and → move the selection even while typing in search, because what the user wants
        // is to pick a card, not to move the text cursor. These run before the text field sees
        // the key, because the handler sits above it in the view tree.
        .onKeyPress(.leftArrow) {
            model.selectPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            model.selectNext()
            return .handled
        }
        // Return pastes the selected card; ⇧Return pastes it as plain text. The handler gets
        // the modifier keys with the press, so one handler covers both.
        .onKeyPress(keys: [.return]) { press in
            model.pasteSelected(plainText: press.modifiers.contains(.shift))
            return .handled
        }
        // ⌘1–⌘9 paste the card with that number on its badge; with ⇧ as plain text. A digit
        // without ⌘ is left alone (`.ignored`) so it still types into the search box.
        .onKeyPress(characters: .decimalDigits) { press in
            guard press.modifiers.contains(.command), let number = Int(press.characters) else {
                return .ignored
            }
            model.paste(shortcutNumber: number, plainText: press.modifiers.contains(.shift))
            return .handled
        }
        // Esc. `onExitCommand` is SwiftUI's name for the Escape key (and ⌘. ) on the Mac.
        .onExitCommand(perform: dismiss)
    }
}
