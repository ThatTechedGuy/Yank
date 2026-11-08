// ApplicationServices is the framework with the Accessibility (AX) C functions; AppKit gives us
// NSWorkspace, which opens a link in the app that handles it (here, System Settings).
import AppKit
import ApplicationServices
import ClipCore

// The real Accessibility permission, behind ClipCore's `AccessibilityStatus` port. The
// permission is tied to the app's code signature (see project.yml), so a rebuild signed with
// the same certificate keeps it; an unsigned build would lose it on every rebuild.
/// `AXIsProcessTrusted` as an `AccessibilityStatus`.
@MainActor public final class SystemAccessibilityStatus: AccessibilityStatus {
    public init() {}

    public var isTrusted: Bool { AXIsProcessTrusted() }

    // macOS has a call that shows its own "would like to control this computer" dialog
    // (`AXIsProcessTrustedWithOptions` with the prompt option), but from inside the App Sandbox
    // it does nothing: the dialog comes from a system service the sandbox won't let Yank reach
    // (the log says "denied lookup: com.apple.universalaccessAuthWarn … Sandbox restriction").
    // So, like other sandboxed apps, we open System Settings at Privacy & Security ›
    // Accessibility instead, where the user switches Yank on, or adds it with + first. Opening a
    // link is allowed from the sandbox, because macOS opens it on Yank's behalf. (≈ an Android
    // app sending the user to Settings with an ACTION_ACCESSIBILITY_SETTINGS intent.) The
    // `x-apple.systempreferences:` link names the settings pane and the section inside it.
    public func requestAccess() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
