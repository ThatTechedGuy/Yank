import ApplicationServices
import ClipCore

// The permission is tied to the app's code signature (see project.yml), so a rebuild signed with
// the same certificate keeps it; an unsigned build would lose it on every rebuild.
/// `AXIsProcessTrusted` as an `AccessibilityStatus`.
@MainActor public final class SystemAccessibilityStatus: AccessibilityStatus {
    public init() {}

    public var isTrusted: Bool { AXIsProcessTrusted() }

    public func requestAccess() {
        // The dialog comes from a system service, com.apple.universalaccessAuthWarn, which the
        // App Sandbox normally won't let Yank reach (the call then does nothing, and the log
        // says "denied lookup … Sandbox restriction"); Yank.entitlements allows that one
        // service by name. The option's name is spelled out because Swift 6 refuses the C
        // constant `kAXTrustedCheckOptionPrompt` (a global variable, which strict concurrency
        // checking treats as unsafe shared state). Its value is this string.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}
