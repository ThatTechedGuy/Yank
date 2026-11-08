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
    /// Takes the user to where the permission is granted (System Settings › Privacy &
    /// Security › Accessibility), so they can switch Yank on there.
    func requestAccess()
}
