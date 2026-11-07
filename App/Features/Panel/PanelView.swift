// What the panel shows: a thin drag handle along the top edge, a search box (with a hint next
// to it when Yank may not press ⌘V) and the row of cards under it. It also owns the keyboard:
// where the cursor goes when the panel opens, what Tab, ← →, Return, ⌘1–⌘9, Space and Esc do.
// The window shell (PanelWindow) decides where on screen the panel is and how tall; this view
// decides what is in it, and asks the shell to change the height when the handle is dragged.
// ≈ the screen component that a native container renders.
// QuickLook is the framework behind the `.quickLookPreview` modifier below.
import ClipCore
import QuickLook
import SwiftUI

struct PanelView: View {
    let model: PanelModel
    /// What Esc does. The window passes in "hide me", so this view never has to know about
    /// AppKit windows and can be previewed on its own.
    let dismiss: () -> Void
    /// Asks the window for a new height, in points, while the handle is dragged. The window
    /// keeps it within the allowed range and remembers it.
    let resize: (CGFloat) -> Void

    /// The two places the keyboard focus can be. SwiftUI tracks focus with a `@FocusState`
    /// value: setting it moves the cursor, and clicking something sets it. ≈ a `ref.focus()`
    /// you can also read. `nil` means nothing in the panel has focus.
    private enum Focus { case search, cards }
    @FocusState private var focus: Focus?
    /// The panel's height and the pointer's screen position when a drag on the handle began;
    /// nil between drags.
    @State private var dragStart: (height: CGFloat, mouseY: CGFloat)?

    var body: some View {
        // `@Bindable` lets a text field write into an `@Observable` model: `$model.searchText`
        // is the two-way binding (≈ value + onChange in one).
        @Bindable var model = model
        GeometryReader { geometry in
            VStack(spacing: 8) {
                resizeHandle(panelHeight: geometry.size.height)
                HStack(spacing: 12) {
                    // The search box. A plain `TextField` bound to the model's text; the model
                    // searches on every change, so there is nothing to wire here.
                    TextField("Search history…", text: $model.searchText)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .search)
                        .accessibilityIdentifier("search")
                    // One line next to search, only while Return cannot paste for the user.
                    // The button opens macOS's own permission dialog; nothing else in the app
                    // ever prompts. It sits in the top bar rather than above the cards so the
                    // panel keeps its height and the cards their size.
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
                // A scrolling row cannot take keyboard focus on its own; `focusable()` lets Tab
                // land on it so typing stops going into the search box.
                CardRow(model: model)
                    .focusable()
                    .focused($focus, equals: .cards)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The frosted-glass look of system panels: what is behind shows through, blurred.
        .background(.regularMaterial)
        // Quick Look for images and files. Setting the model's URL opens the system's preview
        // panel on that file; clearing it, or the user closing the panel, sets it back to nil.
        .quickLookPreview($model.quickLookURL)
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
        // Space opens or closes the selected card's preview, unless the user is typing a
        // search with words in it: then it is a space in the text. `.ignored` passes it on.
        .onKeyPress(.space) {
            if focus == .search, !model.searchText.isEmpty { return .ignored }
            model.togglePreview()
            return .handled
        }
        // Esc closes the preview if one is open, else the panel. `onExitCommand` is SwiftUI's
        // name for the Escape key (and ⌘. ) on the Mac.
        .onExitCommand {
            if model.showsPreview { model.closePreview() } else { dismiss() }
        }
    }

    /// The strip along the top edge the user drags to make the panel taller or shorter. It is
    /// drawn as a short bar in the middle, like the grab handle on an iOS sheet, but the whole
    /// strip takes the drag. The cursor turns into the up/down resize arrows over it.
    private func resizeHandle(panelHeight: CGFloat) -> some View {
        Capsule()
            .fill(.secondary.opacity(0.5))
            .frame(width: 48, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 14)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            // The pointer is read in screen coordinates (`NSEvent.mouseLocation`, y upwards)
            // rather than from the gesture, because the gesture measures from the panel's
            // own top-left corner, which is the very edge being moved. The panel's bottom
            // edge stays on the Dock, so moving the pointer up by 10 points makes it 10
            // points taller.
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        let mouseY = NSEvent.mouseLocation.y
                        let start = dragStart ?? (height: panelHeight, mouseY: mouseY)
                        dragStart = start
                        resize(start.height + mouseY - start.mouseY)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .accessibilityIdentifier("resize-handle")
    }
}
