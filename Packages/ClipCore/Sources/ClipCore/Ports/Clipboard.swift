import Foundation

// Ports: what the core needs from macOS, so the capture loop and the rules are testable with
// fakes. ClipSystem implements them. They are main-actor because NSPasteboard is main-thread only.

/// Whether macOS lets this app read the clipboard without a prompt (macOS 15.4+). Mirrors the
/// states macOS keeps in System Settings; see SystemClipboard for the mapping.
public enum ClipboardAccess: Equatable, Sendable {
    /// The user allowed it for good (AppKit's `.alwaysAllow`), or macOS has not asked yet
    /// (`.default`). Reads work; in the not-asked case the first read shows the "Paste from Other
    /// Apps" prompt and the answer sets the state.
    case allowed
    /// The user did not allow it for good (AppKit's `.ask`), so macOS may show the prompt again on
    /// every read. Also what we report for any state a later macOS adds that we don't know.
    case askEachTime
    /// The user chose "Deny": reads come back empty, so nothing is saved.
    case denied
}

/// The clipboard, as much of it as the capture loop and a paste need.
@MainActor public protocol Clipboard: AnyObject {
    /// A counter macOS bumps on every copy. Cheap to read; the loop polls it.
    var changeCount: Int { get }
    /// Reads the clipboard with a veto. `decide` gets the type names of every pasteboard item
    /// (free to read: no permission prompt, no data in memory); the data is read only if it
    /// returns true, within the size limits (see SystemClipboard). Returns nil when `decide` said
    /// no. Names and data come from one snapshot, so a copy that lands in between cannot slip
    /// past the privacy check.
    func read(if decide: ([String]) -> Bool) -> [ClipboardItemData]?
    /// Replaces the clipboard with these types, grouped back into pasteboard items by
    /// `pasteboardItemIndex`. Writing counts as a copy: `changeCount` goes up.
    func write(_ data: [ClipboardItemData])
    /// The current permission state.
    var access: ClipboardAccess { get }
}

/// The app in front right now: the one that just copied.
@MainActor public protocol FrontmostApp: AnyObject {
    /// `nil` when no app is in front (the desktop) or it has no bundle id.
    func current() -> SourceApp?
}
