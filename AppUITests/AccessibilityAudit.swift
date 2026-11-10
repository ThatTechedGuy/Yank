// Runs Apple's accessibility audit (the Audit button in Xcode's Accessibility Inspector) in the
// UI tests. Any issue fails the test except the few excused below, which come from Apple's own
// controls; anything new fails until it is fixed or added here with its own reason.
import XCTest

extension XCUIApplication {
    /// Audits the app's windows as they are on screen right now and fails the calling test on
    /// every issue not excused below.
    @MainActor
    func auditAccessibility() throws {
        // Contrast is left out. On macOS it measures text against the window's see-through
        // background as captured, and fails plain black text in Apple's standard controls,
        // which the app draws with the system's own colours. Contrast is checked by hand
        // instead, with Increase Contrast switched on.
        try performAccessibilityAudit(for: .all.subtracting(.contrast)) { issue in
            guard let element = issue.element else {
                // "Parent/Child mismatch" with no element named: nothing to fix. It appears with
                // SwiftUI's lazily built rows, whose off-screen children come and go.
                return issue.auditType == .parentChild
            }
            switch (issue.auditType, element.elementType) {
            case (.sufficientElementDescription, .group)
            where element.identifier.isEmpty && element.label.isEmpty:
                // The unnamed container SwiftUI puts around every window's content, Apple's
                // Settings window included.
                return true
            case (.action, .popUpButton), (.action, .menuButton):
                // Pop-up menus (a Picker, the filter menu) open with VoiceOver's "show menu"
                // command rather than "press", which this check does not count. They are
                // Apple's controls and work with VoiceOver and the keyboard.
                return true
            default:
                // The failure message names only the kind of issue; this names the element.
                print(
                    "accessibility issue: \(issue.compactDescription) on \(element.elementType.rawValue) "
                        + "id=\(element.identifier) label=\(element.label) frame=\(element.frame)")
                return false
            }
        }
    }
}
