// The panel's window: the one piece of AppKit in the app's UI. It is a bar along the bottom of
// the screen that takes your keystrokes without making Yank the active app, so the app you
// were working in keeps its focus and a paste can land in it. SwiftUI has no window that
// can do that, so this small class sets up an `NSPanel` (AppKit's window for tool palettes and
// overlays, like Spotlight's bar) and puts the SwiftUI panel view inside it.
//
// Android analogy: an overlay window type that is drawn over everything and does not take the
// foreground away from the app behind it.
//
// It is created once at launch and kept hidden. Showing it is then only "move it to the right
// screen and order it front", which is what makes opening fast.
import AppKit
import ClipCore
import SwiftUI

final class PanelWindow: NSPanel {
    /// The panel's height in points. Paste's default; resizing comes later.
    static let height: CGFloat = 332

    private let model: PanelModel

    init(model: PanelModel) {
        self.model = model
        // The style says what kind of window this is. `borderless`: no title bar, no close
        // buttons, no frame. `nonactivatingPanel`: it can take keyboard focus (become the "key
        // window") without making Yank the active app, so the app behind keeps its active
        // title bar and gets the paste later. (`defer: false` means create the window now.)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Which "layer" of the screen it sits on, like a z-index. `mainMenu` is above normal
        // windows and above the Dock, so nothing covers the panel.
        level = .mainMenu
        // Show on every desktop Space and over full-screen apps. Without `fullScreenAuxiliary`,
        // macOS would switch away from a full-screen app to show the panel.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Like Paste: it stays where we put it, has no shadow and does not hide when Yank stops
        // being the active app (it never is, see above). `isReleasedWhenClosed = false` keeps
        // the one instance alive when hidden, so it can be shown again.
        isMovable = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // No fade or zoom when ordering the window in and out: it should feel instant.
        animationBehavior = .none
        // The SwiftUI content. `NSHostingView` is the bridge that draws a SwiftUI view inside
        // an AppKit window, like a React Native root view inside a native Activity. The view
        // gets a `dismiss` callback for Esc, so SwiftUI never has to know about the window.
        // `[weak self]` keeps the view from holding the window alive in a loop.
        contentView = NSHostingView(
            rootView: PanelView(
                model: model, dismiss: { [weak self] in Task { await self?.hide() } }))
    }

    /// Set while `hide()` is waiting for AppKit to tell us the keyboard has moved on. (A
    /// continuation is the handle for "resume the paused async function"; ≈ the `resolve` of a
    /// Promise you create by hand.)
    private var resignKeyWaiter: CheckedContinuation<Void, Never>?

    // A borderless window refuses keyboard focus unless told otherwise; the panel needs it for
    // the search box and the arrow keys. (`override` replaces the parent class's version.)
    override var canBecomeKey: Bool { true }

    /// Shows the panel along the bottom of the screen the mouse is on, full width, above the
    /// Dock, and gives it keyboard focus. Does nothing if it is already showing.
    func show() {
        guard !isVisible else { return }
        // The screen under the mouse pointer, or the main screen if the pointer is between
        // screens. `visibleFrame` is the screen minus the menu bar and the Dock, so the panel's
        // bottom edge sits just above the Dock. (Screen coordinates start at the bottom left.)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            setFrame(
                NSRect(x: area.minX, y: area.minY, width: area.width, height: Self.height),
                display: false)
        }
        // Order it in front of every other window and make it the key window (the one that
        // receives keystrokes). Because of `nonactivatingPanel`, Yank itself stays inactive.
        makeKeyAndOrderFront(nil)
        model.didShow()
    }

    /// Hides the panel and returns once it has given up the keyboard. The app behind never lost
    /// focus, so there is nothing to give back; but while this window is still the *key* window
    /// a ⌘V would land in our search box, so a paste must wait for AppKit's `resignKey()` call
    /// before pressing it. Ordering the window out is what makes AppKit pick a new key window
    /// and call that; on current macOS it happens before `orderOut` returns, and this still
    /// works if a later macOS does it a moment afterwards.
    func hide() async {
        guard isVisible else { return }
        if isKeyWindow {
            await withCheckedContinuation { continuation in
                resignKeyWaiter = continuation
                orderOut(nil)
            }
        } else {
            orderOut(nil)
        }
        model.didHide()
    }

    // A mouse wheel only rolls up and down, but the row only goes sideways, so rolling the
    // wheel over the panel would do nothing. This turns an up/down wheel step into a sideways
    // one, the same mapping macOS uses for ⇧ + wheel. Trackpads are left alone: their
    // two-finger swipe already goes sideways, and they report "precise" deltas, which is how
    // the two are told apart. Every event for this window passes through `sendEvent` first.
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .scrollWheel, !event.hasPreciseScrollingDeltas,
            event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
            let swapped = event.cgEvent?.copy()
        else {
            super.sendEvent(event)
            return
        }
        // An NSEvent cannot be edited, so edit a copy of the lower-level event it wraps and
        // wrap that. Axis 1 is up/down, axis 2 sideways; each has three fields (the step count,
        // the amount in points, and a fixed-point amount) that all have to move together.
        let steps = swapped.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let points = swapped.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let fixed = swapped.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        swapped.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        swapped.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        swapped.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        swapped.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: steps)
        swapped.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: points)
        swapped.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixed)
        super.sendEvent(NSEvent(cgEvent: swapped) ?? event)
    }

    // AppKit calls this when the window stops being the key window, for two reasons. Either
    // `hide()` ordered it out and is waiting for exactly this call: then the waiter is resumed
    // and nothing else is needed. Or the user clicked somewhere else (another app's window, the
    // desktop, the menu bar) and that place took the keyboard: that is the "click outside"
    // signal, so the panel hides. `super` keeps the parent's own behaviour.
    override func resignKey() {
        super.resignKey()
        resignKeyWaiter?.resume()
        resignKeyWaiter = nil
        if isVisible {
            orderOut(nil)
            model.didHide()
        }
    }
}
