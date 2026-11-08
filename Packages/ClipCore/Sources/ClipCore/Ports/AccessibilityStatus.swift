// A port (≈ a TS interface) for the Accessibility permission. Pressing a key in another app
// needs it: it is the macOS permission that lets one app control others (System Settings ›
// Privacy & Security › Accessibility; ≈ enabling an AccessibilityService on Android). The real
// version asks macOS; tests use a fake set to allowed or not, because changing the real
// permission takes a person clicking in System Settings.
//
// Apple's word for "has the permission" is *trusted* (`AXIsProcessTrusted`), so that is the
// name here too.

/// Whether macOS lets this app control other apps, which pressing ⌘V needs.
@MainActor public protocol AccessibilityStatus: AnyObject {
    /// True when the user has allowed Yank under Accessibility in System Settings.
    var isTrusted: Bool { get }
    /// Shows macOS's own "Yank would like to control this computer" dialog, which adds Yank to
    /// the Accessibility list for the user to switch on. Does nothing when already trusted.
    func requestAccess()
}
