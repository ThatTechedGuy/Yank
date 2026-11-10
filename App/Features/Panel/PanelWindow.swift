// The panel's window: a bar along the bottom of the screen that takes keystrokes without making
// Yank the active app, so the app behind keeps its focus and a paste can land in it. SwiftUI has
// no window that can do that, hence an `NSPanel`. It is created once at launch and kept hidden,
// which is what makes opening fast.
import AppKit
import ClipCore
import ClipSystem
import QuickLookUI
import SwiftUI

final class PanelWindow: NSPanel {
    /// The defaults key for the height the user dragged the panel to.
    static let heightKey = "panelHeight"

    private let model: PanelModel
    /// Always within `PanelHeight`'s range. 0 from the defaults means "never saved".
    private var height: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: PanelWindow.heightKey)
        return PanelHeight.clamped(saved == 0 ? PanelHeight.initial : saved)
    }()

    init(
        model: PanelModel, thumbnails: ThumbnailCache, appIcons: SourceAppIcons,
        openSettings: @escaping () -> Void
    ) {
        self.model = model
        // `nonactivatingPanel`: it can become the key window without making Yank the active app.
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Above normal windows and the Dock, so nothing covers the panel.
        level = .mainMenu
        // Without `fullScreenAuxiliary`, macOS would switch away from a full-screen app to show
        // the panel.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Yank is never the active app, so hiding on deactivate would hide the panel at once.
        isMovable = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Never drawn (there is no title bar), but VoiceOver uses it as the window's name.
        title = "Yank"
        // The view gets callbacks, so SwiftUI never has to know about the window.
        contentView = NSHostingView(
            rootView: PanelView(
                model: model, dismiss: { [weak self] in Task { await self?.hide() } },
                resize: { [weak self] in self?.resize(to: $0) }, openSettings: openSettings
            )
            .environment(thumbnails)
            .environment(\.sourceAppIcons, appIcons))
    }

    /// Set while `hide()` is waiting for AppKit to say the keyboard has moved on.
    private var resignKeyWaiter: CheckedContinuation<Void, Never>?

    // A borderless window refuses keyboard focus unless told otherwise.
    override var canBecomeKey: Bool { true }

    /// Shows the panel along the bottom of the screen the mouse is on, full width, above the
    /// Dock, and gives it keyboard focus. Does nothing if it is already showing.
    func show() {
        guard !isVisible else { return }
        // `.none` leaves the window out of screen recordings and shared screens (a hardware
        // capture card cannot be stopped). Read on every show, so a change in Settings counts
        // from the next open.
        sharingType =
            UserDefaults.standard.bool(forKey: SettingsKey.showPanelInScreenSharing) ? .readOnly : .none
        // The screen under the pointer, or the main screen if the pointer is between screens.
        // `visibleFrame` leaves out the Dock, so the panel sits just above it.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            setFrame(
                NSRect(x: area.minX, y: area.minY, width: area.width, height: height),
                display: false)
        }
        makeKeyAndOrderFront(nil)
        model.didShow()
    }

    /// Hides the panel and returns once it has given up the keyboard. While this window is
    /// still the key window a ⌘V would land in the search box, so a paste must wait for
    /// AppKit's `resignKey()` call. On current macOS that happens before `orderOut` returns;
    /// this still works if a later macOS does it a moment afterwards.
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

    /// Makes the panel the given height, within the allowed range, keeping its bottom edge
    /// where it is, and remembers the height for the next launch.
    func resize(to requested: CGFloat) {
        let clamped = PanelHeight.clamped(requested)
        guard clamped != height else { return }
        height = clamped
        setFrame(NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: clamped), display: true)
        UserDefaults.standard.set(Double(clamped), forKey: Self.heightKey)
    }

    // A mouse wheel only rolls up and down, but the row only goes sideways. This turns an
    // up/down wheel step into a sideways one, as macOS does for ⇧ + wheel. Trackpads already
    // swipe sideways; they report "precise" deltas, which is how the two are told apart.
    override func sendEvent(_ event: NSEvent) {
        guard event.type == .scrollWheel, !event.hasPreciseScrollingDeltas,
            event.scrollingDeltaX == 0, event.scrollingDeltaY != 0,
            let swapped = event.cgEvent?.copy()
        else {
            super.sendEvent(event)
            return
        }
        // An NSEvent cannot be edited, so edit a copy of the CGEvent it wraps. Axis 1 is
        // up/down, axis 2 sideways; each has three fields that all have to move together.
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

    // Called for two reasons. Either `hide()` ordered the window out and is waiting for this
    // call, or the user clicked somewhere else, which is the "click outside" signal to hide.
    // Which window took over is only known one turn of the main loop later. Two exceptions:
    // the large preview is a window of our own and becomes the key window, so the panel stays.
    // And Quick Look's panel takes the keyboard from nobody (Yank is never the active app), so
    // keystrokes would fall through to the app behind; the panel takes the keyboard back
    // instead (Quick Look tries twice, when it opens and when its content loads). A mouse
    // button held down outside both panels at that moment is a real click elsewhere.
    override func resignKey() {
        super.resignKey()
        if let waiter = resignKeyWaiter {
            resignKeyWaiter = nil
            waiter.resume()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, isVisible, NSApp.keyWindow == nil else { return }
            if QLPreviewPanel.sharedPreviewPanelExists(), let quickLook = QLPreviewPanel.shared(),
                quickLook.isVisible, !clickedOutside(quickLook)
            {
                place(quickLook)
                observe(quickLook)
                makeKey()
            } else {
                orderOut(nil)
                model.didHide()
            }
        }
    }

    /// Whether a mouse button is down right now somewhere outside this panel and Quick Look.
    private func clickedOutside(_ quickLook: QLPreviewPanel) -> Bool {
        let mouse = NSEvent.mouseLocation
        return NSEvent.pressedMouseButtons != 0 && !frame.contains(mouse) && !quickLook.frame.contains(mouse)
    }

    /// A click inside the Quick Look panel does make it the key window. From then on it closes
    /// itself on Esc and on a click elsewhere, and this panel hears nothing, so it listens to
    /// Quick Look instead: on Esc the panel takes the keyboard back; on a click elsewhere it
    /// hides.
    private var quickLookObservers: [any NSObjectProtocol] = []

    private func observe(_ quickLook: QLPreviewPanel) {
        guard quickLookObservers.isEmpty else { return }
        let center = NotificationCenter.default
        quickLookObservers = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: quickLook, queue: .main) {
                [weak self] _ in
                // Delivered on the main queue (`queue: .main`), which the compiler cannot see.
                MainActor.assumeIsolated {
                    guard let self, self.isVisible, NSApp.keyWindow == nil else { return }
                    self.makeKey()
                }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: quickLook, queue: .main) {
                [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, isVisible, NSApp.keyWindow == nil else { return }
                    orderOut(nil)
                    model.didHide()
                }
            },
        ]
    }

    /// Moves the Quick Look panel to the middle of the space above this panel. Quick Look
    /// opens on the screen it last used, which with two displays can be the other one.
    private func place(_ quickLook: QLPreviewPanel) {
        guard let screen else { return }
        let above = NSRect(
            x: screen.visibleFrame.minX, y: frame.maxY, width: screen.visibleFrame.width,
            height: screen.visibleFrame.maxY - frame.maxY)
        var target = quickLook.frame
        target.size.height = min(target.height, above.height)
        target.origin = NSPoint(x: above.midX - target.width / 2, y: above.midY - target.height / 2)
        quickLook.setFrame(target, display: true)
    }
}
