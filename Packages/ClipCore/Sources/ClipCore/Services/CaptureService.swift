import Foundation

// Notices copies and saves them. macOS has no "clipboard changed" event, so the app polls: every
// 0.25 s it reads `changeCount`, a cheap integer macOS bumps on every copy. When it moves, the
// service waits a short settle time (some apps write the clipboard in two steps, e.g. text first,
// then the RTF), then reads the clipboard once, letting `PrivacyRules` veto before any data is read, and
// hands the data to the Store.
//
// `@MainActor` on the class means all of its state is only ever touched on the main thread, and
// the compiler checks that. That is what NSPasteboard requires, and it means no locks are needed.
// The heavy work (hashing, SQLite, files) happens inside `Store.save`, which is `async` and runs
// off the main thread, so a big copy never freezes the menu.
//
// `final class` because the app keeps one instance and gives it callbacks; a struct would be
// copied. ≈ a singleton service object in Android, or a module-level object in TS.
/// Watches the clipboard and saves what you copy.
@MainActor public final class CaptureService {
    private let clipboard: any Clipboard
    private let frontmostApp: any FrontmostApp
    private let store: Store
    /// The privacy rules. A `var` because the user can add or remove ignored apps while the
    /// app runs; the app writes the new list here and the next copy is judged by it.
    public var rules: PrivacyRules
    /// Whether the user has paused saving. `.running` unless the menu bar says otherwise; the
    /// app sets it and reads it back to draw the paused icon.
    public var pause: PauseState = .running
    private let settle: Duration

    /// The change count we last handled. Set at start, so what is already on the clipboard when
    /// the app launches is never saved.
    private var lastChangeCount: Int

    /// Called after every save, on the main thread, with the saved item. The app uses it to
    /// update the "N items saved" menu. ≈ an event emitter with one listener.
    public var onCapture: ((ClipboardItem) -> Void)?

    // Everything the service talks to comes in through here, so the app passes the real
    // clipboard and tests pass fakes with a tiny settle time. `any Clipboard` means "some object
    // that implements the Clipboard protocol, whichever one"; Swift 6 makes you write `any` so
    // the extra lookup is visible. `Duration` is Swift's time span type (`.milliseconds(300)`),
    // ≈ a Kotlin Duration.
    public init(
        clipboard: any Clipboard, frontmostApp: any FrontmostApp, store: Store,
        rules: PrivacyRules = PrivacyRules(), settle: Duration = .milliseconds(300)
    ) {
        self.clipboard = clipboard
        self.frontmostApp = frontmostApp
        self.store = store
        self.rules = rules
        self.settle = settle
        lastChangeCount = clipboard.changeCount
    }

    /// Whether macOS lets us read the clipboard. The app shows a hint when it doesn't.
    public var clipboardAccess: ClipboardAccess { clipboard.access }

    /// One poll. The app calls this every 0.25 s; tests call it directly.
    /// Returns once the change (if any) has been handled, so tests don't have to wait.
    public func tick() async throws {
        let count = clipboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        // Paused: this copy is never saved, not even after the pause ends, because the change
        // count was just marked as handled. The clipboard is not read at all.
        if pause.isPaused(at: Date()) {
            Log.capture.info("paused, skipped a copy")
            return
        }
        // Record who copied, and when, *now*, before the settle wait: by the time the data is
        // read the user may have switched apps. Plain locals, because nothing outside this one
        // tick needs them.
        let sourceApp = frontmostApp.current()
        let copiedAt = Date()
        try await Task.sleep(for: settle)
        // If another copy landed during the wait, this one is stale: reading now would save the
        // newer content under the older app. The next tick sees the newer count and handles it.
        guard clipboard.changeCount == count else { return }
        // Ask the rules and read in one step. The clipboard hands the type names to the closure
        // first; only if it answers "yes" is any data read, and from the same snapshot, so a copy
        // that lands in between cannot slip past the privacy check. The decision is kept in a
        // local so the switch below can log why nothing was saved. (A closure may change a `var`
        // declared outside it, like a JS arrow function can.)
        var decision = CaptureDecision.skip
        let data = clipboard.read { types in
            decision = rules.decision(types: types, sourceApp: sourceApp?.bundleId)
            return decision == .save
        }
        switch decision {
        case .skip:
            Log.capture.info("skipped a copy from \(sourceApp?.bundleId ?? "?", privacy: .public)")
        case .moveOwnPasteToTop:
            // Our own paste: PasteService already moved the item to the top when it wrote the
            // clipboard, so there is nothing to save and nothing to move.
            Log.capture.debug("own paste, nothing to save")
        case .save:
            guard let data, !data.isEmpty else {
                // Happens when access is denied (reads come back empty) or an app cleared the
                // clipboard. Nothing to save, but worth knowing about in the log.
                Log.capture.notice("clipboard changed but nothing could be read")
                return
            }
            let copy = CapturedCopy(data: data, sourceApp: sourceApp, copiedAt: copiedAt)
            let item = try await store.save(copy)
            onCapture?(item)
        }
    }
}
