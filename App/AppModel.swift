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
    /// The folder holding this launch's database and large-data files: the real one, or the
    /// fake-history one when started with `--seed`.
    let dataFolder: URL
    /// Whether, and until when, saving is paused from the menu. Kept here (not on disk): a
    /// pause ends when the app quits, which is the safe way round for a privacy switch.
    /// Every change is passed on to the capture service, which is what actually skips copies.
    private(set) var pause: PauseState = .running {
        didSet { capture?.pause = pause }
    }
    /// `pause` as a yes/no for right now, for the icon and the menu. A timed pause ends on its
    /// own, so the poll loop refreshes this when the time comes.
    private(set) var isPaused = false
    /// The paste stack: off, or on with the copies made since it was turned on waiting in
    /// order. The menu bar shows its count and its items; ⌃⌥⌘V pastes the oldest.
    private(set) var stack = PasteStack.off

    private var capture: CaptureService?
    private var store: Store?
    private var pasteService: PasteService?
    /// The preview maker and the cards' picture cache, kept for the editor: a saved edit gets
    /// its preview like a fresh copy, and a replaced card's old picture is dropped.
    private var enricher: Enricher?
    private var thumbnails: ThumbnailCache?
    /// The panel's window, created once and kept hidden until ⇧⌘V. Nil if the store failed.
    private var panel: PanelWindow?
    /// Selects one card in the panel, by id: what the editor calls after a save, so the panel
    /// comes back with the saved card outlined rather than the one that was selected before.
    private var selectCard: (Int64) -> Void = { _ in }

    /// Whether the panel is on screen right now. Read by the Developer window, which pauses its
    /// own sampling while the panel is up so it never overlaps a panel-open or search timing.
    var isPanelVisible: Bool { panel?.isVisible ?? false }

    init() {
        let options = LaunchOptions()
        dataFolder = options.storeFolder
        // Open the database before anything else starts. Nothing in the app works without it, and it
        // is a local file, so opening it here is quick. If it fails we keep the error so the menu can
        // show it instead of crashing. (`do { try ... } catch` is Swift's try/catch.)
        do {
            let store = try Store(folder: dataFolder)
            // One clipboard object for both capture and paste, so the paste service's "that
            // was my own write" marker and the capture loop's change counter stay in step.
            let clipboard = SystemClipboard()
            let capture = CaptureService(
                clipboard: clipboard, frontmostApp: FrontmostAppReader(), store: store)
            self.capture = capture
            self.store = store
            clipboardAccess = capture.clipboardAccess
            watchIgnoredApps()
            // Pasting: the service puts an item on the clipboard and presses ⌘V in the app
            // behind the panel. Its system pieces (key presser, permission check) come from
            // ClipSystem, so ClipCore and its tests never touch real keys.
            let pasteService = PasteService(
                store: store, clipboard: clipboard, keyPresser: KeyPresser(),
                accessibility: SystemAccessibilityStatus())
            self.pasteService = pasteService
            // Previews: the Enricher makes them after each save with ClipSystem's decoders (a
            // thumbnail, the words in an image, a link's page title and icon), the cache keeps
            // the ones the cards draw, and the icon cache gives each card its app's icon and
            // header colour. The link switch is read on every fetch, so a change in Settings
            // counts from the next copy; ClipCore itself never reads UserDefaults.
            let enricher = Enricher(
                store: store, makePreview: Thumbnailer.preview, recognizeText: TextRecognizer.text(in:),
                linkFetcher: LinkFetcher(), linkPreviewsEnabled: { SettingsKey.linkPreviewsEnabled })
            // The panel and its state. Built now, while nothing is urgent, so that the first
            // ⇧⌘V only has to put an existing window on screen.
            let panelModel = PanelModel(store: store, pasteService: pasteService)
            let thumbnails = ThumbnailCache(store: store, enricher: enricher)
            self.enricher = enricher
            self.thumbnails = thumbnails
            let panel = PanelWindow(
                model: panelModel, thumbnails: thumbnails, appIcons: SourceAppIcons(),
                openSettings: { [weak self] in self?.openSettings() })
            self.panel = panel
            // "Add to Stack" in a card's menu queues the card by hand, whether or not the
            // stack is on: the stack is this model's, so the panel is handed a way to reach it.
            // "Edit" and ⌘N open the editor window, which is this model's too.
            panelModel.addToStack = { [weak self] item in self?.add(toStack: item) }
            panelModel.openEditor = { [weak self] item in self?.edit(item) }
            selectCard = { [weak panelModel] id in panelModel?.selectedId = id }
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
                // While the stack is on, every copy joins its queue; a repeat copy is a new
                // copy and joins too. The app's own pastes never reach here (the capture loop
                // skips its marker), so pasting from the stack cannot feed the stack.
                self?.stack.add(item)
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

    /// Watches the global shortcuts for as long as Yank runs: ⇧⌘V shows or hides the panel,
    /// ⌃⌥⌘V pastes the next item from the stack, and the (unset by default) stack key turns
    /// the stack on or off.
    private func watchShortcut() {
        Task { [weak self] in
            // Each press is one value of an endless async stream (≈ `for await` over an event
            // iterator). `.keyDown` only: a shortcut also reports its release, which we ignore.
            for await _ in KeyboardShortcuts.events(.keyDown, for: .togglePanel) {
                self?.togglePanel()
            }
        }
        Task { [weak self] in
            for await _ in KeyboardShortcuts.events(.keyDown, for: .pasteNext) {
                self?.pasteNext()
            }
        }
        Task { [weak self] in
            for await _ in KeyboardShortcuts.events(.keyDown, for: .toggleStack) {
                self?.toggleStack()
            }
        }
    }

    /// The menu bar's "Turn Paste Stack On/Off". Turning it off drops the queue; the items
    /// are still in the history.
    func toggleStack() {
        if stack.isOn { stack.turnOff() } else { stack.turnOn() }
        Log.paste.info("paste stack \(self.stack.isOn ? "on" : "off", privacy: .public)")
    }

    /// Queues a card from its menu. The stack is turned on first if it was off, so the card
    /// is not silently dropped.
    func add(toStack item: ClipboardItem) {
        stack.turnOn()
        stack.add(item)
    }

    /// ⌃⌥⌘V: pastes the oldest queued item into the app in front, with the user's paste
    /// settings, and takes it off the queue. Nothing waiting: nothing happens. The item leaves
    /// the queue before the paste, so a paste that can only reach the clipboard (no
    /// Accessibility permission) still moves the stack along.
    func pasteNext() {
        guard let pasteService, let item = stack.popNext() else { return }
        Task {
            do {
                try await pasteService.paste(
                    item, plainText: PasteSettings.alwaysPlainText, destination: PasteSettings.destination)
            } catch {
                Log.paste.error("paste next failed: \(error, privacy: .public)")
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
            // A timed pause ends between two ticks; this is where the icon finds out.
            let paused = pause.isPaused(at: Date())
            if paused != isPaused {
                isPaused = paused
                if !paused { pause = .running }
            }
            // Wait a quarter second before looking again: often enough that a copy is saved before the
            // user pastes it, rare enough to cost nothing. `tolerance` lets macOS wake us up to 25 ms
            // late so it can batch our timer with others and save power.
            try? await Task.sleep(for: .milliseconds(250), tolerance: .milliseconds(25))
        }
    }

    /// "Open Panel" in the menu: the same as the shortcut, so the timing log covers it too.
    func openPanel() {
        togglePanel()
    }

    /// Opens the editor on a card, or empty (nil) for a new text item. The panel goes away
    /// first: the editor is a real window and makes Yank the active app, which the panel never
    /// does. After a save the panel comes back with the result in it and selected, and the
    /// menu's count is re-read, since a new item was made or an old one changed.
    func edit(_ item: ClipboardItem?) {
        guard let store, let enricher, let thumbnails else { return }
        let editor = ItemEditor(original: item, store: store, enricher: enricher, thumbnails: thumbnails)
        editor.didSave = { [weak self] saved in
            self?.panel?.show()
            self?.selectCard(saved.id)
            Task { [weak self] in
                self?.itemCount = (try? await store.count()) ?? 0
            }
        }
        Task { [weak self] in
            await self?.panel?.hide()
            EditorWindow(editor: editor).open()
        }
    }

    /// Stops saving for a while, from now. Takes effect on the next clipboard check, and shows
    /// at once in the icon and the menu.
    func pause(for duration: Duration) {
        pause = .paused(for: duration, from: Date())
        isPaused = true
    }

    /// Stops saving until `resume()`.
    func pauseUntilResumed() {
        pause = .pausedUntilResumed
        isPaused = true
    }

    /// Starts saving again. A copy made while paused is not saved after the fact.
    func resume() {
        pause = .running
        isPaused = false
    }

    /// Deletes every item that is not on a pinboard, with its files, then shrinks the database
    /// file. The panel's list follows the database on its own; the menu's count is re-read here.
    func eraseHistory() {
        guard let store else { return }
        Task { [weak self] in
            do {
                try await store.eraseHistory()
            } catch {
                Log.store.error("erase failed: \(error, privacy: .public)")
            }
            self?.itemCount = (try? await store.count()) ?? 0
        }
    }

    /// Opens the Settings window from the panel (⌘,). The panel never makes Yank the active
    /// app, so the window would open behind whatever the user was working in; `activate()`
    /// first brings Yank forward. `openSettings` is SwiftUI's action for its `Settings` scene,
    /// taken from a fresh environment because this is not a view.
    func openSettings() {
        Task { [weak self] in
            await self?.panel?.hide()
            NSApp.activate()
            EnvironmentValues().openSettings()
        }
    }

    /// Keeps the capture rules' ignored apps equal to the list in Settings. The list lives in
    /// UserDefaults (a preference, so it survives "Erase History"), and ClipCore knows nothing
    /// about UserDefaults, so the app copies it across: once now, and again whenever any
    /// default changes, which is how the Settings window's edits reach the capture loop.
    /// UserDefaults posts one notification for any change, so this runs a little more often
    /// than needed; the copy is a few strings, so that is fine.
    private func watchIgnoredApps() {
        capture?.rules.ignoredApps = Set(IgnoredApps.current.bundleIds)
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue (`queue: .main`), which the compiler cannot see.
            MainActor.assumeIsolated {
                self?.capture?.rules.ignoredApps = Set(IgnoredApps.current.bundleIds)
            }
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
