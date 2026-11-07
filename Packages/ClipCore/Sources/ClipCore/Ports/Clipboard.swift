import Foundation

// A *port*: a protocol (≈ a TS interface) the core talks to instead of a macOS framework, so the
// capture loop and the rules can be tested without a real clipboard. ClipSystem implements it
// over NSPasteboard; the tests implement it with a fake, the way you'd mock an interface in Jest.
//
// `@MainActor` on the protocol means every call must happen on the main thread. NSPasteboard is
// only safe there, and with this mark the compiler checks our callers for us. `AnyObject` limits
// it to classes, so the real one can be a single long-lived object rather than a copied value.

/// Whether macOS lets this app read the clipboard without a prompt (macOS 15.4+). Mirrors the
/// states macOS keeps in System Settings; see SystemClipboard for the mapping.
public enum ClipboardAccess: Equatable, Sendable {
    /// The user allowed it for good (AppKit's `.alwaysAllow`), or macOS has not asked yet
    /// (`.default`). Reads work; in the not-asked case the first read shows the "Paste from Other
    /// Apps" prompt and the answer sets the state.
    case allowed
    /// The user did not allow it for good (AppKit's `.ask`), so macOS may show the prompt again on
    /// every read. The app shows a hint with a link to System Settings. Also what we report for
    /// any state a later macOS adds that we don't know.
    case askEachTime
    /// The user chose "Deny": reads come back empty, so nothing is saved.
    case denied
}

/// The clipboard, as much of it as the capture loop needs.
@MainActor public protocol Clipboard: AnyObject {
    /// A counter macOS bumps on every copy. Cheap to read; the loop polls it.
    var changeCount: Int { get }
    /// Reads the clipboard in one go, with a veto. First `decide` gets the type names of every
    /// pasteboard item (names are free to read: no permission prompt, no data in memory). Only
    /// when it returns true is the data of those same items read, honouring the size limits
    /// (see SystemClipboard). Returns nil when `decide` said no, so the caller knows nothing
    /// was read. One call, one snapshot: the names and the data come from the same moment, so a
    /// copy that lands in between cannot slip past the privacy check.
    func read(if decide: ([String]) -> Bool) -> [ClipboardItemData]?
    /// The current permission state.
    var access: ClipboardAccess { get }
}

/// The app in front right now: the one that just copied.
@MainActor public protocol FrontmostApp: AnyObject {
    /// `nil` when no app is in front (the desktop) or it has no bundle id.
    func current() -> SourceApp?
}
