// The Logs tab: this launch's log lines, newest at the top, with a category filter. Reading the
// system log is slow (see LogReader), so the tab reads when it appears, every five seconds while it
// is showing and the panel is not open, and whenever Refresh is pressed.
#if DEBUG
    import ClipCore
    import SwiftUI

    struct LogsView: View {
        let model: AppModel

        /// How many lines are kept, so the window's memory stays flat however long it is open.
        static let keptLines = 500
        /// Seconds between automatic reads.
        static let refreshEvery = 5

        @State private var reader: LogReader?
        @State private var lines: [LogLine] = []
        /// The chosen category; nil shows every category.
        @State private var category: String?
        @State private var isReading = false
        @State private var error: String?

        /// Every category seen so far, for the filter menu.
        private var categories: [String] {
            Array(Set(lines.map(\.category))).sorted()
        }

        /// Newest first, so the latest line is at the top without scrolling.
        private var shownLines: [LogLine] {
            lines.reversed().filter { category == nil || $0.category == category }
        }

        var body: some View {
            Table(shownLines) {
                TableColumn("Time") {
                    Text($0.date, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                }
                .width(100)
                TableColumn("Level") { Text($0.levelName) }.width(50)
                TableColumn("Category") { Text($0.category) }.width(70)
                TableColumn("Message") { Text($0.message).textSelection(.enabled) }
            }
            .toolbar {
                Picker("Category", selection: $category) {
                    Text("All").tag(String?.none)
                    ForEach(categories, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .pickerStyle(.menu)
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await read() }
                }
                .disabled(isReading)
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text(
                            "\(shownLines.count) lines · info and above, this launch only · private values stay hidden"
                        )
                    }
                    Spacer()
                    if isReading { ProgressView().controlSize(.small) }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(8)
                .background(.bar)
            }
            .task { await readEveryFewSeconds() }
        }

        private func readEveryFewSeconds() async {
            do {
                reader = try LogReader()
            } catch {
                self.error = "Could not open the log store: \(error.localizedDescription)"
                return
            }
            while !Task.isCancelled {
                if !model.isPanelVisible { await read() }
                try? await Task.sleep(for: .seconds(Self.refreshEvery))
            }
        }

        /// One read: appends the new lines and drops the oldest beyond the limit.
        private func read() async {
            guard let reader, !isReading else { return }
            isReading = true
            defer { isReading = false }
            do {
                let fresh = try await reader.newLines()
                if !fresh.isEmpty { lines = Array((lines + fresh).suffix(Self.keptLines)) }
            } catch {
                self.error = "Could not read the log: \(error.localizedDescription)"
            }
        }
    }
#endif
