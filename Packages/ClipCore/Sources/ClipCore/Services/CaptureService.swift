import Foundation

// macOS has no "clipboard changed" event, so the app polls `changeCount` every 0.25 s. When it
// moves, the service waits a short settle time before reading, because some apps write the
// clipboard in two steps (text first, then the RTF).
/// Watches the clipboard and saves what you copy.
@MainActor public final class CaptureService {
    private let clipboard: any Clipboard
    private let frontmostApp: any FrontmostApp
    private let store: Store
    /// The privacy rules. The app writes a new value when the user adds or removes ignored apps,
    /// and the next copy is judged by it.
    public var rules: PrivacyRules
    /// Whether the user has paused saving. The app sets it and reads it back to draw the paused
    /// icon.
    public var pause: PauseState = .running
    private let settle: Duration

    /// The change count we last handled. Set at start, so what is already on the clipboard when
    /// the app launches is never saved.
    private var lastChangeCount: Int

    /// Called after every save, on the main thread, with the saved item.
    public var onCapture: ((ClipboardItem) -> Void)?

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
        // Record who copied, and when, now, before the settle wait: by the time the data is read
        // the user may have switched apps.
        let sourceApp = frontmostApp.current()
        let copiedAt = Date()
        try await Task.sleep(for: settle)
        // If another copy landed during the wait, this one is stale: reading now would save the
        // newer content under the older app. The next tick sees the newer count and handles it.
        guard clipboard.changeCount == count else { return }
        // Ask the rules and read in one step. The clipboard hands the type names to the closure
        // first; only if it answers "yes" is any data read, and from the same snapshot, so a copy
        // that lands in between cannot slip past the privacy check.
        var decision = CaptureDecision.skip
        let data = clipboard.read { types in
            decision = rules.decision(types: types, sourceApp: sourceApp?.bundleId)
            return decision == .save
        }
        switch decision {
        case .skip:
            Log.capture.info("skipped a copy from \(sourceApp?.bundleId ?? "?", privacy: .public)")
        case .moveOwnPasteToTop:
            // Our own paste: PasteService already moved the item to the top, so there is nothing
            // to save and nothing to move.
            Log.capture.debug("own paste, nothing to save")
        case .save:
            guard let data, !data.isEmpty else {
                // Happens when access is denied (reads come back empty) or an app cleared the
                // clipboard.
                Log.capture.notice("clipboard changed but nothing could be read")
                return
            }
            let copy = CapturedCopy(data: data, sourceApp: sourceApp, copiedAt: copiedAt)
            let item = try await store.save(copy)
            onCapture?(item)
        }
    }
}
