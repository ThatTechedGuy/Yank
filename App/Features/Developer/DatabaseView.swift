// The Database tab: the newest rows of the `clipboardItem` table, with each row's kind, source
// app, time and how many bytes of clipboard data it carries, plus the size of the search index.
// It re-reads only after something was written (the inspector checks SQLite's change counter once
// a second), so a quiet database costs one tiny query per second and nothing else.
//
// There is no place to type SQL on purpose: DB Browser for SQLite does that far better, on the
// same file, which "Open Data Folder" in the menu bar menu takes you to.
#if DEBUG
    import ClipCore
    import SwiftUI

    struct DatabaseView: View {
        let model: AppModel
        let inspector: StoreInspector

        /// How many of the newest items the table shows.
        static let rowLimit = 50

        @State private var snapshot: StoreInspector.Snapshot?
        @State private var error: String?

        var body: some View {
            // `Table` is the macOS multi-column list (≈ a data grid). Each `TableColumn` names a
            // column and says how to draw one row's cell; `value:` takes a key path straight to
            // a String property and makes the column sortable later.
            Table(snapshot?.newestItems ?? []) {
                TableColumn("Card text", value: \.cardText)
                TableColumn("Kind") { Text($0.kind.rawValue) }.width(60)
                TableColumn("App") { Text($0.sourceAppName ?? "") }.width(100)
                TableColumn("Copied") {
                    Text($0.copiedAt, format: .dateTime.month().day().hour().minute().second())
                }
                .width(150)
                TableColumn("Data") {
                    Text(Int64($0.dataBytes).formatted(.byteCount(style: .file)))
                }
                .width(80)
            }
            .safeAreaInset(edge: .bottom) {
                // A one-line status bar under the table.
                HStack {
                    if let snapshot {
                        Text(
                            "Newest \(snapshot.newestItems.count) of \(snapshot.itemCount) items · search index: \(snapshot.searchIndexRowCount) rows"
                        )
                    } else if let error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("Reading…")
                    }
                    Spacer()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(8)
                .background(.bar)
            }
            .task { await refreshEverySecond() }
        }

        /// Once a second, asks the inspector for a fresh snapshot; it answers nil when nothing was
        /// written since the last one. Paused while the panel is open.
        private func refreshEverySecond() async {
            while !Task.isCancelled {
                if !model.isPanelVisible {
                    do {
                        if let fresh = try await inspector.snapshot(
                            ifChangedSince: snapshot?.dataVersion, newestLimit: Self.rowLimit)
                        {
                            snapshot = fresh
                        }
                    } catch {
                        self.error = "Could not read the database: \(error.localizedDescription)"
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
#endif
