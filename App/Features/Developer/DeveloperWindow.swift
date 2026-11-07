// The Developer window: a second window, in debug builds only, for watching the app from the
// inside while building it. Four tabs: Overview (counts, sizes, memory, CPU), Database (the
// newest rows), Timings (how long the panel takes to open, as a chart against its limit) and
// Logs (the app's own log lines). ≈ Android Studio's App Inspection tab, or the React Native dev
// menu: `#if DEBUG` is Swift's `__DEV__`, except the compiler drops the code from a release build
// entirely, so the shipped app has none of it.
//
// Every file in this folder is wrapped in `#if DEBUG`, and nothing outside this folder depends on
// it: YankApp.swift adds the window and the menu items under the same `#if DEBUG`.
//
// Everything each tab does starts in that tab's `.task` and stops when the tab or the window
// goes away (SwiftUI cancels the task), so with the window closed the app does no extra work at
// all. ≈ a `useEffect` whose cleanup runs on unmount.
#if DEBUG
    import AppKit
    import ClipCore
    import SwiftUI

    /// The "Developer" window scene. Declared once in YankApp; opened by `DeveloperMenuItems`.
    struct DeveloperWindow: Scene {
        /// The id `openWindow` uses to find this scene, and the window's title.
        static let id = "developer"
        static let title = "Developer"

        let model: AppModel

        var body: some Scene {
            // A `Window` is a single window that can be opened and closed, as opposed to
            // `WindowGroup`, which would open a new copy on every request. The standard window
            // chrome, sidebar and toolbar come from macOS; nothing here is styled by hand.
            Window(Self.title, id: Self.id) {
                DeveloperView(model: model)
            }
            .defaultSize(width: 820, height: 760)
        }
    }

    /// The two rows the menu bar menu gains in a debug build.
    struct DeveloperMenuItems: View {
        let model: AppModel
        // `openWindow` is SwiftUI's way to open a `Window` scene by id, read from the environment
        // (≈ a navigation prop injected by the router).
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            Button("Developer…") {
                openWindow(id: DeveloperWindow.id)
                // Yank is a menu bar app with no Dock icon, so it is never the active app. Opening
                // a window does not change that by itself; without this the window would appear
                // behind whatever app is in front.
                NSApplication.shared.activate()
            }
            Button("Open Data Folder") {
                // Shows the folder in a Finder window with the database file selected. Finder hides
                // ~/Library, so this is the easiest way to reach it. It is this launch's folder:
                // the fake-history one when started with `--seed`.
                NSWorkspace.shared.activateFileViewerSelecting([
                    model.dataFolder.appending(path: "yank.sqlite")
                ])
            }
        }
    }

    /// The four sidebar entries.
    enum DeveloperTab: String, CaseIterable, Identifiable {
        case overview, database, timings, logs

        var id: Self { self }

        var title: String {
            switch self {
            case .overview: "Overview"
            case .database: "Database"
            case .timings: "Timings"
            case .logs: "Logs"
            }
        }

        /// The SF Symbol shown next to the title in the sidebar.
        var systemImage: String {
            switch self {
            case .overview: "gauge.with.dots.needle.33percent"
            case .database: "cylinder"
            case .timings: "timer"
            case .logs: "text.alignleft"
            }
        }
    }

    /// The window's content: a sidebar of tabs and the selected tab's view.
    struct DeveloperView: View {
        let model: AppModel
        @State private var tab: DeveloperTab? = .overview
        /// The read-only database connection every tab shares. Opened when the window appears
        /// and dropped when it closes, so a closed window holds no connection.
        @State private var inspector: StoreInspector?
        @State private var openError: String?

        var body: some View {
            // Sidebar on the left, the selected tab on the right. `List(selection:)` turns the
            // sidebar into a radio list bound to `tab`.
            NavigationSplitView {
                List(DeveloperTab.allCases, selection: $tab) { tab in
                    Label(tab.title, systemImage: tab.systemImage)
                }
                .navigationSplitViewColumnWidth(160)
            } detail: {
                if let inspector {
                    switch tab ?? .overview {
                    case .overview: OverviewView(model: model, inspector: inspector)
                    case .database: DatabaseView(model: model, inspector: inspector)
                    case .timings: TimingsView(model: model)
                    case .logs: LogsView(model: model)
                    }
                } else if let openError {
                    ContentUnavailableView(
                        "Could not open the database", systemImage: "exclamationmark.triangle",
                        description: Text(openError))
                } else {
                    ProgressView()
                }
            }
            .task {
                do {
                    inspector = try StoreInspector(folder: model.dataFolder)
                } catch {
                    openError = error.localizedDescription
                }
            }
        }
    }
#endif
