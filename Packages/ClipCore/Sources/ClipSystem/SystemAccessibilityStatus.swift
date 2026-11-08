// ApplicationServices is the framework with the Accessibility (AX) C functions.
import ApplicationServices
import ClipCore

// The real Accessibility permission, behind ClipCore's `AccessibilityStatus` port. The
// permission is tied to the app's code signature (see project.yml), so a rebuild signed with
// the same certificate keeps it; an unsigned build would lose it on every rebuild.
/// `AXIsProcessTrusted` as an `AccessibilityStatus`.
@MainActor public final class SystemAccessibilityStatus: AccessibilityStatus {
    public init() {}

    public var isTrusted: Bool { AXIsProcessTrusted() }

    public func requestAccess() {
        // The same check with the "prompt" option: when not trusted, macOS shows its own
        // "Yank would like to control this computer" dialog, which adds Yank to the
        // Accessibility list in System Settings with the switch off, for the user to turn on.
        // The dialog comes from a system service, com.apple.universalaccessAuthWarn, which the
        // App Sandbox normally won't let Yank reach (the call then does nothing, and the log
        // says "denied lookup … Sandbox restriction"); Yank.entitlements allows that one
        // service by name. The option's name is spelled out because Swift 6 refuses the C
        // constant `kAXTrustedCheckOptionPrompt` (it is declared as a global variable, which
        // strict concurrency checking treats as unsafe shared state). Its value is this string.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}
