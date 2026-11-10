// What the panel shows: the resize handle, the search box, the tabs and the row of cards. It
// also owns the panel's keyboard handling. PanelWindow decides where the panel is and how tall.
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
    /// What ⌘, does: hides the panel and opens Settings. Passed in for the same reason as
    /// `dismiss`.
    let openSettings: () -> Void

    /// The two places the keyboard focus can be.
    private enum Focus { case search, cards }
    @FocusState private var focus: Focus?
    /// The panel's height and the pointer's screen position when a drag on the handle began;
    /// nil between drags.
    @State private var dragStart: (height: CGFloat, mouseY: CGFloat)?

    var body: some View {
        @Bindable var model = model
        GeometryReader { geometry in
            VStack(spacing: 8) {
                resizeHandle(panelHeight: geometry.size.height)
                HStack(spacing: 12) {
                    TextField(model.searchPrompt, text: $model.searchText)
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .search)
                        // The grey prompt inside the box is not a name VoiceOver can use.
                        .accessibilityLabel("Search")
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
                PanelTabs(model: model)
                // Focusable so Tab can land on the row and typing stops going into the search
                // box. No focus ring: the selected card's outline already shows where the keys
                // go, and a ring around the whole row looked like a stray outline.
                CardRow(model: model)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($focus, equals: .cards)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .quickLookPreview($model.quickLookURL)
        // Every time the panel opens, the cursor goes to search so the user can type at once.
        .onChange(of: model.isVisible, initial: true) { _, visible in
            if visible { focus = .search }
        }
        // Tab moves between search and the cards and back; SwiftUI would otherwise only move
        // it forward and then out of the panel. The handlers below also hear the keys typed in
        // a popover, because the popover hangs off this view; while one is open they return
        // `.ignored` so the key reaches the popover.
        .onKeyPress(.tab) {
            guard !model.isPrompting else { return .ignored }
            focus = focus == .search ? .cards : .search
            return .handled
        }
        // ← and → move the selection even while typing in search: the user wants to pick a
        // card, not to move the text cursor. With ⇧ held they extend the selection.
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard !model.isPrompting else { return .ignored }
            let step = press.key == .leftArrow ? -1 : 1
            if press.modifiers.contains(.shift) {
                model.extendSelection(by: step)
            } else if step < 0 {
                model.selectPrevious()
            } else {
                model.selectNext()
            }
            return .handled
        }
        // ⌫ deletes the selected cards, after asking. Plain ⌫ only when the cards have focus
        // or the search box is empty: otherwise it is erasing search text. ⌘⌫ always does.
        // The Mac's ⌫ key types U+007F, not the U+0008 that SwiftUI's `.delete` stands for,
        // so both are listed.
        .onKeyPress(keys: [.delete, KeyEquivalent("\u{7F}")]) { press in
            let erasingSearch = focus == .search && !model.searchText.isEmpty
            if model.isPrompting || erasingSearch && !press.modifiers.contains(.command) {
                return .ignored
            }
            model.confirmDelete(of: model.selectedItems)
            return .handled
        }
        // Return pastes the selected cards; ⇧Return pastes them as plain text.
        .onKeyPress(keys: [.return]) { press in
            guard !model.isPrompting else { return .ignored }
            model.pasteSelected(plainText: press.modifiers.contains(.shift))
            return .handled
        }
        // ⌘1–⌘9 paste the card with that number on its badge; with ⇧ as plain text. A digit
        // without ⌘ still types into the search box.
        .onKeyPress(characters: .decimalDigits) { press in
            guard press.modifiers.contains(.command), let number = Int(press.characters) else {
                return .ignored
            }
            model.paste(shortcutNumber: number, plainText: press.modifiers.contains(.shift))
            return .handled
        }
        // Space opens or closes the selected card's preview, unless the search box has focus
        // and text in it: then it is a space in the text.
        .onKeyPress(.space) {
            if model.isPrompting || focus == .search && !model.searchText.isEmpty { return .ignored }
            model.togglePreview()
            return .handled
        }
        // Esc (or ⌘.) closes a popover if one is open, else the preview, else the panel.
        .onExitCommand {
            if model.isPrompting {
                model.closePrompts()
            } else if model.showsPreview {
                model.closePreview()
            } else {
                dismiss()
            }
        }
        // ⌘, opens Settings. Yank has no menu bar of its own while the panel is up (it is not
        // the active app), so the key has to be caught here.
        .onKeyPress(.init(","), phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            openSettings()
            return .handled
        }
        // ⌘[ and ⌘] move one tab left or right, wrapping round; ⌘P pins or unpins the selected card.
        .onKeyPress(.init("["), phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            model.selectPreviousTab()
            return .handled
        }
        .onKeyPress(.init("]"), phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            model.selectNextTab()
            return .handled
        }
        .onKeyPress(.init("p"), phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            model.togglePin()
            return .handled
        }
        // ⌘K opens the actions menu on the selected card; ⌘A selects every card in the row
        // (the search box loses its usual ⌘A, which is the trade made here).
        .onKeyPress(.init("k"), phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            model.openActions()
            return .handled
        }
        .onKeyPress(.init("a"), phases: .down) { press in
            guard press.modifiers == .command else { return .ignored }
            model.selectAll()
            return .handled
        }
        // ⌘E opens the selected card in the editor; ⌘N opens an empty editor for a new text
        // item. Both close the panel, since the editor is a window of its own.
        .onKeyPress(.init("e"), phases: .down) { press in
            guard press.modifiers == .command, !model.isPrompting else { return .ignored }
            model.editSelected()
            return .handled
        }
        .onKeyPress(.init("n"), phases: .down) { press in
            guard press.modifiers == .command, !model.isPrompting else { return .ignored }
            model.openEditor(nil)
            return .handled
        }
    }

    /// The strip along the top edge the user drags to make the panel taller or shorter. It is
    /// drawn as a short bar in the middle, but the whole strip takes the drag.
    private func resizeHandle(panelHeight: CGFloat) -> some View {
        Capsule()
            .fill(.secondary.opacity(0.5))
            .frame(width: 48, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 14)
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .top))
            // The pointer is read in screen coordinates (y upwards) rather than from the
            // gesture, because the gesture measures from the panel's own top-left corner, which
            // is the very edge being moved. The panel's bottom edge stays put, so moving the
            // pointer up by 10 points makes it 10 points taller.
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
            // VoiceOver users cannot drag, so to them the handle is a slider: it says the
            // height, and increase and decrease move it 20 points within the allowed range.
            .accessibilityRepresentation {
                Slider(
                    value: Binding(get: { Double(panelHeight) }, set: { resize(CGFloat($0)) }),
                    in: PanelHeight.minimum...PanelHeight.maximum, step: 20
                ) {
                    Text("Panel height")
                }
                .accessibilityValue("\(Int(panelHeight)) points")
            }
            .accessibilityIdentifier("resize-handle")
    }
}
