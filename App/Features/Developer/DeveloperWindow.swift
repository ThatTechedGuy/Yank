// The Developer window, in debug builds only: Overview, Database, Timings and Logs tabs. Each tab's
// work starts in its `.task` and is cancelled when the tab or the window goes away, so with the
// window closed the app does no extra work at all.
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
            Window(Self.title, id: Self.id) {
                DeveloperView(model: model)
            }
            .defaultSize(width: 820, height: 760)
        }
    }

    /// The two rows the menu bar menu gains in a debug build.
    struct DeveloperMenuItems: View {
        let model: AppModel
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            Button("Developer…") {
                openWindow(id: DeveloperWindow.id)
                // Yank is seldom the active app, and opening a window does not make it so; without
                // this the window would appear behind whatever app is in front.
                NSApplication.shared.activate()
            }
            Button("Open Data Folder") {
                // This launch's folder: the fake-history one when started with `--seed`.
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
