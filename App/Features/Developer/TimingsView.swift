// The Timings tab: a bar chart per timing marker ("Open panel" and "Search") of its last durations,
// with the app's limits drawn across as lines. The durations come from `Log.timing`, which
// remembers the last 20 of each name in a debug build.
#if DEBUG
    import Charts
    import ClipCore
    import SwiftUI

    struct TimingsView: View {
        let model: AppModel

        /// The speed limits, in milliseconds, by marker name. A name that is not here still
        /// gets a chart, just without a line.
        static let limits: [String: [(label: String, milliseconds: Double)]] = [
            "Open panel": [("50 ms limit", 50)],
            "Search": [("16 ms with 10k items", 16), ("33 ms with 100k items", 33)],
        ]

        @State private var intervals: [TimingInterval] = []

        /// Marker names in the order they were first seen.
        private var names: [String] {
            var seen: [String] = []
            for interval in intervals where !seen.contains(interval.name) { seen.append(interval.name) }
            return seen
        }

        var body: some View {
            ScrollView {
                if intervals.isEmpty {
                    ContentUnavailableView(
                        "No timings yet", systemImage: "timer",
                        description: Text("Press ⇧⌘V to open the panel; each open adds a bar."))
                } else {
                    VStack(spacing: 16) {
                        ForEach(names, id: \.self) { name in
                            GroupBox(name) { chart(for: name) }
                        }
                    }
                    .padding()
                }
            }
            .task { await refreshEverySecond() }
        }

        /// One marker's bars, oldest on the left, and its limit lines.
        private func chart(for name: String) -> some View {
            let runs = intervals.filter { $0.name == name }
            let limits = Self.limits[name] ?? []
            return Chart {
                // The x axis is the run's position: a plain 1, 2, 3 reads better than a timestamp
                // for a few tries.
                ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                    BarMark(
                        x: .value("Try", index + 1),
                        y: .value("Milliseconds", milliseconds(run.duration))
                    )
                }
                ForEach(limits, id: \.label) { limit in
                    RuleMark(y: .value("Limit", limit.milliseconds))
                        .foregroundStyle(.red)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text(limit.label).font(.caption).foregroundStyle(.red)
                        }
                }
            }
            .chartXScale(domain: 0...(TimingSignposter.keptPerName + 1))
            .chartYAxisLabel("ms")
            .frame(height: 180)
        }

        /// A duration as a number of milliseconds, with the fraction kept.
        private func milliseconds(_ duration: Duration) -> Double {
            let parts = duration.components
            return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        }

        /// Copies the remembered intervals once a second, except while the panel is open.
        private func refreshEverySecond() async {
            while !Task.isCancelled {
                if !model.isPanelVisible {
                    let latest = Log.timing.recentIntervals
                    if latest != intervals { intervals = latest }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
#endif
