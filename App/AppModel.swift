// The app's one shared state object. It opens the database, owns the capture service, runs the
// loop that watches the clipboard, and holds the three values the menu shows. ≈ a root
// Zustand/Redux store, or an Android ViewModel that outlives every screen.
//
// The menu must re-render when the count or the permission state changes. `@Observable` gives us
// that: it generates code at compile time (like a Babel plugin or an annotation processor) that
// tracks every stored property, so a SwiftUI view that reads `model.itemCount` re-renders when it
// changes. No `@Published`, no `useState`.
//
// project.yml makes everything in this target run on the main thread unless it says otherwise, so
// this class is main-thread only without spelling it out. CaptureService requires that.
import ClipCore
import ClipSystem
import KeyboardShortcuts
import SwiftUI

@Observable final class AppModel {
    /// Number of saved items, shown in the menu. Updated after every capture.
    private(set) var itemCount = 0
    /// The clipboard permission state, re-read on every poll so the menu follows System Settings.
    private(set) var clipboardAccess: ClipboardAccess = .allowed
    /// Set when the store could not open: shown in the menu instead of the count.
    private(set) var startupError: String?

    private var capture: CaptureService?
    /// The panel's window, created once and kept hidden until ⇧⌘V. Nil if the store failed.
    private var panel: PanelWindow?

    init() {
        // Open the database before anything else starts. Nothing in the app works without it, and it
        // is a local file, so opening it here is quick. If it fails we keep the error so the menu can
        // show it instead of crashing. (`do { try ... } catch` is Swift's try/catch.)
        do {
            let options = LaunchOptions()
            let store = try Store(folder: options.storeFolder)
            // One clipboard object for both capture and paste, so the paste service's "that
            // was my own write" marker and the capture loop's change counter stay in step.
            let clipboard = SystemClipboard()
            let capture = CaptureService(
                clipboard: clipboard, frontmostApp: FrontmostAppReader(), store: store)
            self.capture = capture
            clipboardAccess = capture.clipboardAccess
            // Pasting: the service puts an item on the clipboard and presses ⌘V in the app
            // behind the panel. Its system pieces (key presser, permission check) come from
            // ClipSystem, so ClipCore and its tests never touch real keys.
            let pasteService = PasteService(
                store: store, clipboard: clipboard, keyPresser: KeyPresser(),
                accessibility: SystemAccessibilityStatus())
            // Previews: the Enricher makes them after each save with ClipSystem's decoders, the
            // cache keeps the ones the cards draw, and the icon cache gives each card its app's
            // icon and header colour.
            let enricher = Enricher(store: store, makePreview: Thumbnailer.preview)
            // The panel and its state. Built now, while nothing is urgent, so that the first
            // ⇧⌘V only has to put an existing window on screen.
            let panel = PanelWindow(
                model: PanelModel(store: store, pasteService: pasteService),
                thumbnails: ThumbnailCache(store: store, enricher: enricher), appIcons: SourceAppIcons())
            self.panel = panel
            // Before pressing ⌘V the service hides the panel and waits until it has let go of
            // the keyboard, or the ⌘V would land in our own search box. `[weak panel]`: the
            // service must not keep the window alive on its own.
            pasteService.hidePanel = { [weak panel] in await panel?.hide() }
            watchShortcut()
            // After every save, start the item's preview in the background and re-read the number
            // the menu shows. Asking the database instead of adding one keeps the menu right when a
            // save was really a repeat (the item moved to the top, the count did not grow). `[weak
            // self]` stops this callback from keeping the model alive forever: without it the model
            // holds the service, the service holds this callback and the callback holds the model,
            // so none of them could ever be freed. It is the same reason you unsubscribe in a React
            // effect's cleanup.
            capture.onCapture = { [weak self] item in
                enricher.enrichInBackground(item)
                Task { [weak self] in
                    self?.itemCount = (try? await store.count()) ?? 0
                }
            }
            // Read the saved count from the database, then start watching the clipboard. Both need
            // `await` and `init` cannot await, so they run in a `Task` (like calling an async function
            // without awaiting it). The task stays on the main thread; it pauses, not blocks, at each
            // `await`, so the menu stays responsive. `[weak self]` here is only a habit: the loop
            // inside `poll()` holds the model for as long as the app runs anyway, which is fine for
            // the one object that lives as long as the app does.
            Task { [weak self] in
                // Debug-only: fill the database with fake items, and show the panel at once if
                // asked, before the first count so the menu shows the seeded number.
                #if DEBUG
                    if let count = options.seedCount {
                        do {
                            try await store.seed(count: count)
                        } catch {
                            Log.store.error("could not seed: \(error, privacy: .public)")
                        }
                    }
                    if options.showPanel { panel.show() }
                #endif
                self?.itemCount = (try? await store.count()) ?? 0
                await self?.poll()
            }
        } catch {
            Log.store.error("could not open the store: \(error, privacy: .public)")
            startupError = "Could not open the database: \(error.localizedDescription)"
        }
    }

    /// Shows or hides the panel on every press of ⇧⌘V, from any app, for as long as Yank runs.
    private func watchShortcut() {
        Task { [weak self] in
            // Each press is one value of an endless async stream (≈ `for await` over an event
            // iterator). `.keyDown` only: a shortcut also reports its release, which we ignore.
            for await _ in KeyboardShortcuts.events(.keyDown, for: .togglePanel) {
                self?.togglePanel()
            }
        }
    }

    /// Opens the panel, or closes it if it is open, and logs how long opening took: the app has
    /// a speed limit for this, and the log is how to check it.
    private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            Task { await panel.hide() }
            return
        }
        // A timing marker around the whole open, from key press to the window on screen.
        let clock = ContinuousClock()
        let start = clock.now
        let state = Log.timing.beginInterval("Open panel")
        panel.show()
        Log.timing.endInterval("Open panel", state)
        let elapsed = clock.now - start
        let ms = elapsed.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1)))
        Log.ui.info("panel opened in \(ms, privacy: .public)")
    }

    /// Checks the clipboard four times a second until the app quits, saving every new copy.
    private func poll() async {
        // If the database failed to open there is no capture service, so there is nothing to poll.
        // (`guard let` is an early return when the value is missing, like `if (!capture) return`.)
        guard let capture else { return }
        // Nothing ever cancels this task, so the loop runs until the process ends. Checking
        // `Task.isCancelled` anyway is the usual shape of a Swift polling loop.
        while !Task.isCancelled {
            do {
                try await capture.tick()
            } catch {
                Log.capture.error("capture failed: \(error, privacy: .public)")
            }
            // Only assign when the state really changed: every assignment to an `@Observable`
            // property tells SwiftUI to re-render the menu, and four times a second would be waste.
            let access = capture.clipboardAccess
            if access != clipboardAccess { clipboardAccess = access }
            // Wait a quarter second before looking again: often enough that a copy is saved before the
            // user pastes it, rare enough to cost nothing. `tolerance` lets macOS wake us up to 25 ms
            // late so it can batch our timer with others and save power.
            try? await Task.sleep(for: .milliseconds(250), tolerance: .milliseconds(25))
        }
    }

    /// Opens System Settings at Privacy & Security › Paste from Other Apps, where the user can allow
    /// Yank to read the clipboard without being asked each time.
    func openClipboardSettings() {
        // A deep link into System Settings. Apple does not document these URLs; this one was
        // collected by the community (see README), so re-check it after macOS updates.
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!
        NSWorkspace.shared.open(url)
    }
}
