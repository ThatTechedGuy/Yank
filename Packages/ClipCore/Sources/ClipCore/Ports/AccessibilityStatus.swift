// A port so tests can fake the permission: changing the real one takes a person clicking in
// System Settings.

/// Whether macOS lets this app control other apps, which pressing ⌘V needs.
@MainActor public protocol AccessibilityStatus: AnyObject {
    /// True when the user has allowed Yank under Accessibility in System Settings.
    var isTrusted: Bool { get }
    /// Shows macOS's own "Yank would like to control this computer" dialog, which adds Yank to
    /// the Accessibility list for the user to switch on. Does nothing when already trusted.
    func requestAccess()
}
