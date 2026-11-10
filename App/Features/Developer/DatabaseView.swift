// The Database tab: a read-only browser of every table in the SQLite file, one page of rows at a
// time, which is what keeps 100,000 rows cheap. There is no place to type SQL on purpose: `sqlite3`
// does that far better on the same file ("Open Data Folder" in the menu leads to it).
#if DEBUG
    import ClipCore
    import SwiftUI

    struct DatabaseView: View {
        let model: AppModel
        let inspector: StoreInspector

        /// Rows per page. Small enough that a page of long texts or thumbnails stays light.
        static let pageSize = 200

        @State private var tables: StoreInspector.TableList?
        @State private var selectedTable: String?
        @State private var pageIndex = 0
        @State private var page: StoreInspector.Page?
        @State private var error: String?

        /// The chosen table's facts, if it still exists.
        private var table: StoreInspector.TableInfo? {
            tables?.tables.first { $0.name == selectedTable }
        }

        private var pageCount: Int {
            max(1, ((table?.rowCount ?? 0) + Self.pageSize - 1) / Self.pageSize)
        }

        var body: some View {
            grid
                .safeAreaInset(edge: .top) { tablePicker }
                .safeAreaInset(edge: .bottom) { statusBar }
                .task { await refreshEverySecond() }
                // A new table or page: read it now rather than at the next tick.
                .task(id: "\(selectedTable ?? "")#\(pageIndex)") { await loadPage() }
        }

        /// One `Picker` row per table: "clipboardItem · 10,000 rows".
        private var tablePicker: some View {
            HStack {
                Picker("Table", selection: $selectedTable) {
                    ForEach(tables?.tables ?? []) { table in
                        Text("\(table.name) · \(table.rowCount.formatted()) rows")
                            .tag(Optional(table.name))
                    }
                }
                .frame(maxWidth: 360)
                Spacer()
            }
            .padding(8)
            .background(.bar)
        }

        /// One column per column of the chosen table. The rows are plain arrays of cells, so each
        /// is identified by its place on the page. `.id` builds a fresh grid when the table
        /// changes, because a `Table` cannot swap its columns in place.
        private var grid: some View {
            let columns = table?.columns ?? []
            let rows = (page?.rows ?? []).enumerated().map { PageRow(id: $0.offset, cells: $0.element) }
            return Table(rows) {
                TableColumnForEach(columns) { column in
                    TableColumn(column.name) { row in
                        // For a moment after switching tables the rows still belong to the old
                        // one, so a column past their end is drawn empty rather than crashing.
                        let index = columns.firstIndex(of: column) ?? 0
                        CellView(value: index < row.cells.count ? row.cells[index] : .null)
                    }
                }
            }
            .id(selectedTable)
        }

        private var statusBar: some View {
            HStack {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else if let table, table.rowCount == 0 {
                    Text("No rows · \(table.columns.count) columns")
                } else if let table {
                    let first = min(pageIndex * Self.pageSize + 1, table.rowCount)
                    let last = min((pageIndex + 1) * Self.pageSize, table.rowCount)
                    Text(
                        "Rows \(first.formatted())–\(last.formatted()) of \(table.rowCount.formatted()) · \(table.columns.count) columns"
                    )
                } else {
                    Text("Reading…")
                }
                Spacer()
                Button("Previous page", systemImage: "chevron.left") { pageIndex -= 1 }
                    .disabled(pageIndex == 0)
                Text("Page \(pageIndex + 1) of \(pageCount)")
                Button("Next page", systemImage: "chevron.right") { pageIndex += 1 }
                    .disabled(pageIndex + 1 >= pageCount)
            }
            .labelStyle(.iconOnly)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(8)
            .background(.bar)
        }

        /// Reads the chosen table's current page; nothing if no table is chosen yet.
        private func loadPage() async {
            guard let selectedTable else { return }
            do {
                page = try await inspector.page(
                    of: selectedTable, offset: pageIndex * Self.pageSize, limit: Self.pageSize)
                error = nil
            } catch {
                self.error = "Could not read \(selectedTable): \(error.localizedDescription)"
            }
        }

        /// Once a second, asks the inspector for the table list; it answers nil when nothing was
        /// written since the last one. When something was, the open page is re-read too, and the
        /// page index pulled back if the table shrank. Paused while the panel is open.
        private func refreshEverySecond() async {
            while !Task.isCancelled {
                if !model.isPanelVisible {
                    do {
                        if let fresh = try await inspector.tables(ifChangedSince: tables?.dataVersion) {
                            tables = fresh
                            // First open: start on the biggest table, the one worth looking at.
                            if selectedTable == nil {
                                selectedTable = fresh.tables.max { $0.rowCount < $1.rowCount }?.name
                            }
                            pageIndex = min(pageIndex, pageCount - 1)
                            await loadPage()
                        }
                    } catch {
                        self.error = "Could not read the database: \(error.localizedDescription)"
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// One row of the grid: its position on the page and its cells, in column order.
    private struct PageRow: Identifiable {
        let id: Int
        let cells: [StoreInspector.CellValue]
    }

    /// Draws one cell. Numbers and text as they are; NULL dimmed; a blob as its size, with the
    /// text or image inside when the inspector could tell what it was.
    private struct CellView: View {
        let value: StoreInspector.CellValue

        var body: some View {
            switch value {
            case .null:
                Text("NULL").foregroundStyle(.tertiary)
            case .integer(let n):
                Text(n, format: .number.grouping(.never))
            case .real(let d):
                Text(d, format: .number)
            case .text(let s):
                Text(s).lineLimit(1)
            case .blob(let byteCount, let preview):
                HStack(spacing: 6) {
                    Text(Int64(byteCount).formatted(.byteCount(style: .file)))
                        .foregroundStyle(.secondary)
                    switch preview {
                    case .text(let s):
                        Text(s).lineLimit(1)
                    case .image(let data):
                        if let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFit().frame(height: 20)
                        }
                    case nil:
                        EmptyView()
                    }
                }
            }
        }
    }
#endif
