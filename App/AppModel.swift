// The app's one shared state object: it opens the database, owns the capture service, runs the loop
// that watches the clipboard, and holds the values the menu shows. Main-actor through the target's
// default isolation (project.yml), which CaptureService requires.
import ClipCore
import ClipSystem
import KeyboardShortcuts
import SwiftUI

@Observable final class AppModel {
    /// Number of saved items, shown in the menu. Follows the database (`observeCount`), so a
    /// capture, an erase, the editor and the hourly expiry all keep it right without a word.
    private(set) var itemCount = 0
    /// The clipboard permission state, re-read on every poll so the menu follows System Settings.
    private(set) var clipboardAccess: ClipboardAccess = .allowed
    /// Set when the store could not open: shown in the menu instead of the count.
    private(set) var startupError: String?
    /// The folder holding this launch's database and large-data files: the real one, or the
    /// fake-history one when started with `--seed`.
    let dataFolder: URL
    /// Whether, and until when, saving is paused from the menu. Kept here (not on disk): a pause
    /// ends when the app quits, which is the safe way round for a privacy switch.
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
    /// The cards' picture cache, kept for the editor: a saved edit gets its preview like a
    /// fresh copy, and a replaced card's old picture is dropped.
    private var thumbnails: ThumbnailCache?
    /// The panel's window, created once and kept hidden until ⇧⌘V. Nil if the store failed.
    private var panel: PanelWindow?
    /// Selects one card in the panel, by id: what the editor calls after a save, so the panel
    /// comes back with the saved card outlined rather than the one that was selected before.
    private var selectCard: (Int64) -> Void = { _ in }

    /// Whether macOS lets Yank press ⌘V in other apps (Privacy & Security › Accessibility). Asked
    /// fresh on every read: macOS sends no notice when the user flips the switch.
    var isAccessibilityTrusted: Bool { pasteService?.isAccessibilityTrusted ?? false }

    /// Shows macOS's Accessibility prompt, which adds Yank to the list for the user to switch on.
    func requestAccessibility() { pasteService?.requestAccessibility() }

    /// Whether the panel is on screen right now. Read by the Developer window, which pauses its
    /// own sampling while the panel is up so it never overlaps a panel-open or search timing.
    var isPanelVisible: Bool { panel?.isVisible ?? false }

    init() {
        let options = LaunchOptions()
        dataFolder = options.storeFolder
        // The store opens synchronously: it is a local file, and nothing works without it. A
        // failure is kept so the menu can show it.
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
            // The service's system pieces (key presser, permission check) come from ClipSystem, so
            // ClipCore and its tests never touch real keys.
            let pasteService = PasteService(
                store: store, clipboard: clipboard, keyPresser: KeyPresser(),
                accessibility: SystemAccessibilityStatus())
            self.pasteService = pasteService
            // The link switch is read on every fetch, so a change in Settings counts from the next
            // copy; ClipCore itself never reads UserDefaults.
            let enricher = Enricher(
                store: store, makePreview: Thumbnailer.preview, recognizeText: TextRecognizer.text(in:),
                linkFetcher: LinkFetcher(), linkPreviewsEnabled: { SettingsKey.linkPreviewsEnabled })
            // Built now, while nothing is urgent, so the first ⇧⌘V only shows an existing window.
            let panelModel = PanelModel(store: store, pasteService: pasteService)
            let thumbnails = ThumbnailCache(store: store, enricher: enricher)
            self.thumbnails = thumbnails
            let panel = PanelWindow(
                model: panelModel, thumbnails: thumbnails, appIcons: SourceAppIcons(),
                openSettings: { [weak self] in self?.openSettings() })
            self.panel = panel
            // The stack and the editor are this model's; the panel is handed a way to reach them.
            panelModel.addToStack = { [weak self] item in self?.add(toStack: item) }
            panelModel.openEditor = { [weak self] item in self?.edit(item) }
            selectCard = { [weak panelModel] id in panelModel?.selectedId = id }
            // Before pressing ⌘V the service hides the panel and waits until it has let go of the
            // keyboard, or the ⌘V would land in our own search box.
            pasteService.hidePanel = { [weak panel] in await panel?.hide() }
            watchShortcut()
            capture.onCapture = { [weak self] item in
                thumbnails.enrichInBackground(item)
                // While the stack is on, every copy joins its queue; a repeat copy is a new
                // copy and joins too. The app's own pastes never reach here (the capture loop
                // skips its marker), so pasting from the stack cannot feed the stack.
                self?.stack.add(item)
            }
            // One live query for the menu's count instead of re-reading after each place that
            // writes. A repeat copy (item moved up, count unchanged) delivers nothing.
            Task { [weak self] in
                do {
                    for try await count in store.observeCount() { self?.itemCount = count }
                } catch {
                    Log.store.error("count stopped: \(error.logDescription, privacy: .public)")
                }
            }
            Task { [weak self] in
                #if DEBUG
                    if let count = options.seedCount {
                        do {
                            try await store.seed(count: count)
                        } catch {
                            Log.store.error("could not seed: \(error.logDescription, privacy: .public)")
                        }
                    }
                    if options.showPanel { panel.show() }
                #endif
                await self?.poll()
            }
            Task { [weak self] in await self?.expireOldItems(in: store) }
        } catch {
            Log.store.error("could not open the store: \(error.logDescription, privacy: .public)")
            startupError = "Could not open the database: \(error.localizedDescription)"
        }
    }

    /// Watches the global shortcuts for as long as Yank runs: ⇧⌘V shows or hides the panel,
    /// ⌃⌥⌘V pastes the next item from the stack, and the (unset by default) stack key turns
    /// the stack on or off.
    private func watchShortcut() {
        Task { [weak self] in
            // `.keyDown` only: a shortcut also reports its release, which we ignore.
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

    /// ⌃⌥⌘V: pastes the oldest queued item into the app in front and takes it off the queue. The
    /// item leaves before the paste, so a paste that can only reach the clipboard (no Accessibility
    /// permission) still moves the stack along.
    func pasteNext() {
        guard let pasteService, let item = stack.popNext() else { return }
        Task {
            do {
                try await pasteService.paste(
                    item, plainText: PasteSettings.alwaysPlainText, destination: PasteSettings.destination)
            } catch {
                Log.paste.error("paste next failed: \(error.logDescription, privacy: .public)")
            }
        }
    }

    /// Opens the panel, or closes it if it is open, and logs how long opening took: the app has
    /// a speed limit for this, and the log is how to check it.
    func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            Task { await panel.hide() }
            return
        }
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
        guard let capture else { return }
        while !Task.isCancelled {
            do {
                try await capture.tick()
            } catch {
                Log.capture.error("capture failed: \(error.logDescription, privacy: .public)")
            }
            // Assign only on a real change: every assignment to an `@Observable` property
            // re-renders the menu, and four times a second would be waste.
            let access = capture.clipboardAccess
            if access != clipboardAccess { clipboardAccess = access }
            // A timed pause ends between two ticks; this is where the icon finds out.
            let paused = pause.isPaused(at: Date())
            if paused != isPaused {
                isPaused = paused
                if !paused { pause = .running }
            }
            // A quarter second: often enough that a copy is saved before the user pastes it, rare
            // enough to cost nothing. The tolerance lets macOS batch the timer to save power.
            try? await Task.sleep(for: .milliseconds(250), tolerance: .milliseconds(25))
        }
    }

    /// Applies the "Keep history" setting at launch and then once an hour: Yank may stay open for
    /// weeks as a login item. The setting is read on each pass. "Forever" (0, and what a missing
    /// key reads as) deletes nothing.
    private func expireOldItems(in store: Store) async {
        while !Task.isCancelled {
            let days = UserDefaults.standard.integer(forKey: SettingsKey.keepHistoryDays)
            if days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) {
                do {
                    try await store.deleteUnpinned(copiedBefore: cutoff)
                } catch {
                    Log.store.error("could not expire items: \(error.logDescription, privacy: .public)")
                }
            }
            try? await Task.sleep(for: .seconds(3600), tolerance: .seconds(60))
        }
    }

    /// Opens the editor on a card, or empty (nil) for a new text item. The panel goes away
    /// first: the editor is a real window and makes Yank the active app, which the panel never
    /// does. After a save the panel comes back with the result in it and selected.
    func edit(_ item: ClipboardItem?) {
        guard let store, let thumbnails else { return }
        let editor = ItemEditor(original: item, store: store, thumbnails: thumbnails)
        editor.didSave = { [weak self] saved in
            self?.panel?.show()
            self?.selectCard(saved.id)
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
    /// file. The panel's list and the menu's count both follow the database on their own.
    func eraseHistory() {
        guard let store else { return }
        Task {
            do {
                try await store.eraseHistory()
            } catch {
                Log.store.error("erase failed: \(error.logDescription, privacy: .public)")
            }
        }
    }

    /// Opens the Settings window from the panel (⌘,). The panel never makes Yank the active app, so
    /// the window would open behind whatever the user was working in; `activate()` first brings
    /// Yank forward. `openSettings` comes from a fresh environment because this is not a view.
    func openSettings() {
        Task { [weak self] in
            await self?.panel?.hide()
            NSApp.activate()
            EnvironmentValues().openSettings()
        }
    }

    /// Keeps the capture rules' ignored apps equal to the list in Settings. The list lives in
    /// UserDefaults (a preference, so it survives "Erase History") and ClipCore knows nothing about
    /// UserDefaults, so the app copies it across: once now, and again on every defaults change. Not
    /// narrowed to `UserDefaults.standard` (the compiler will not pass it between threads); Yank
    /// has no other defaults, so every such notification is from it anyway.
    private func watchIgnoredApps() {
        capture?.rules.ignoredApps = Set(IgnoredApps.current.bundleIds)
        Task { [weak self] in
            let changes = NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification)
            for await _ in changes {
                self?.capture?.rules.ignoredApps = Set(IgnoredApps.current.bundleIds)
            }
        }
    }

    /// Opens System Settings at Privacy & Security › Paste from Other Apps, where the user can allow
    /// Yank to read the clipboard without being asked each time.
    func openClipboardSettings() {
        // Apple does not document these URLs, so re-check this one after macOS updates.
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!
        NSWorkspace.shared.open(url)
    }
}
