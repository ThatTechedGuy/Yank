// One place for running Apple's accessibility audit in the UI tests, the same checks as the
// Audit button in Xcode's Accessibility Inspector: every element has a name VoiceOver can read,
// controls can be pressed without a mouse, nothing is cut off or too small to hit, and so on.
// The test fails on any issue the audit finds, except the few listed below, which come from
// Apple's own controls rather than from Yank's code and which the app cannot change. Each one
// says why; anything new fails the test until it is fixed or added here with its own reason.
// ≈ running axe-core in a Playwright test with a short, commented list of disabled rules.
import XCTest

extension XCUIApplication {
    /// Audits the app's windows as they are on screen right now and fails the calling test on
    /// every issue not excused below.
    @MainActor
    func auditAccessibility() throws {
        // Contrast is left out. On macOS it measures text against the window's see-through
        // background as captured, and it fails plain black text in Apple's standard controls,
        // such as the labels of a grouped settings form and a window's ordinary heading, which
        // the app draws with the system's own colours. Contrast is checked by hand instead,
        // with Increase Contrast switched on.
        try performAccessibilityAudit(for: .all.subtracting(.contrast)) { issue in
            guard let element = issue.element else {
                // "Parent/Child mismatch" with no element named: the audit cannot say which
                // element it means, so there is nothing to fix; it appears with SwiftUI's
                // lazily built rows, whose off-screen children come and go.
                return issue.auditType == .parentChild
            }
            switch (issue.auditType, element.elementType) {
            case (.sufficientElementDescription, .group)
            where element.identifier.isEmpty && element.label.isEmpty:
                // The unnamed group that fills every SwiftUI window, Apple's Settings window
                // included: the container SwiftUI puts around a window's content. It has no
                // name of its own to give.
                return true
            case (.action, .popUpButton), (.action, .menuButton):
                // Pop-up menus (a Picker, the filter menu) open with VoiceOver's "show menu"
                // command rather than "press", which this check does not count. They are
                // Apple's controls and work with VoiceOver and the keyboard.
                return true
            default:
                // The failure message names only the kind of issue; this line in the test log
                // names the element, which is what you need to fix it.
                print(
                    "accessibility issue: \(issue.compactDescription) on \(element.elementType.rawValue) "
                        + "id=\(element.identifier) label=\(element.label) frame=\(element.frame)")
                return false
            }
        }
    }
}
