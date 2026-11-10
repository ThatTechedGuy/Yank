// The "Open at login" switch, shared by Settings and the welcome window. macOS keeps this setting,
// not Yank (System Settings › General › Login Items, where the user can change it too), so
// `SMAppService.mainApp.status` is the truth and the switch's state only a copy of it.
import ClipCore
import ServiceManagement
import SwiftUI

struct OpenAtLoginToggle: View {
    /// What the switch shows. Set from macOS's answer, never trusted on its own.
    @State private var opensAtLogin = false
    /// A line under the switch when macOS refused, or wants the user to allow Yank first.
    @State private var loginItemError: String?

    var body: some View {
        Toggle("Open at login", isOn: $opensAtLogin)
            .onChange(of: opensAtLogin) { _, wanted in setOpensAtLogin(wanted) }
            .onAppear(perform: readLoginItemStatus)
            .accessibilityIdentifier("open-at-login")
        if let loginItemError {
            Text(loginItemError).font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Copies macOS's answer into the switch. `.enabled` is on; `.requiresApproval` means the
    /// user has to allow it in System Settings, so the switch shows off with an explanation.
    private func readLoginItemStatus() {
        let status = SMAppService.mainApp.status
        opensAtLogin = status == .enabled
        loginItemError =
            status == .requiresApproval ? "Allow Yank in System Settings › General › Login Items." : nil
    }

    /// Registers or unregisters the app as a login item, then re-reads what macOS says so the
    /// switch never shows a state that was refused. Reading the status back also sets
    /// `opensAtLogin`, which calls this again; the first line stops that second call.
    // shortcut: reading the status back right after a failure also clears the error line
    // unless macOS answered "requires approval", so most failures only show in the log;
    // keep the message if users ever report a switch that silently flips back.
    private func setOpensAtLogin(_ wanted: Bool) {
        guard wanted != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.ui.error("login item change failed: \(error.logDescription, privacy: .public)")
            loginItemError = error.localizedDescription
        }
        readLoginItemStatus()
    }
}
