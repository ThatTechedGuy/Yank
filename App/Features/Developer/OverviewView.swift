// The Overview tab: how many items are saved and of which kinds, how big the database and the
// large-data folder are, and what the process costs right now in memory and CPU. The numbers
// refresh once a second while the tab is showing, except while the panel is open, so the
// refresh never overlaps a timing the app is measuring.
//
// A window that watches a process is part of that process, so its own drawing shows up in the
// CPU number. The Measure button is the honest way round that: it hides the window, samples for
// 60 seconds while nothing is drawn, then shows the window again with the result. Instruments
// (outside the process) stays the final word on any number here.
#if DEBUG
    import AppKit
    import ClipCore
    import SwiftUI

    struct OverviewView: View {
        let model: AppModel
        let inspector: StoreInspector

        /// How long the Measure button samples for, with the window hidden.
        static let measureDuration = 60

        @State private var snapshot: StoreInspector.Snapshot?
        @State private var cpuPercent: Double?
        @State private var footprint: Int?
        @State private var isMeasuring = false
        @State private var measurement: Measurement?
        @State private var error: String?

        /// What one press of Measure found.
        struct Measurement {
            let cpuPercent: Double
            let peakFootprint: Int
            let endedAt: Date
        }

        var body: some View {
            // A `Form` with the grouped style is the standard look for a settings-like page of
            // labelled values on macOS. `LabeledContent` is one "label: value" row.
            Form {
                Section("Items") {
                    LabeledContent("Saved", value: snapshot?.itemCount ?? 0, format: .number)
                    ForEach(ItemKind.allCases, id: \.self) { kind in
                        LabeledContent(
                            kind.rawValue.capitalized, value: snapshot?.countsByKind[kind] ?? 0,
                            format: .number)
                    }
                    LabeledContent(
                        "Search index rows", value: snapshot?.searchIndexRowCount ?? 0, format: .number)
                }
                Section("Disk") {
                    LabeledContent("Database", value: bytes(snapshot?.databaseBytes))
                    LabeledContent("Large data files", value: bytes(snapshot?.largeDataBytes))
                    LabeledContent("Folder", value: model.dataFolder.path)
                }
                Section("Process") {
                    LabeledContent("Memory footprint", value: bytes(footprint))
                    LabeledContent("CPU", value: percent(cpuPercent))
                    if let measurement {
                        LabeledContent("Measured with the window hidden") {
                            Text(
                                "\(percent(measurement.cpuPercent)) CPU, peak \(bytes(measurement.peakFootprint)), at \(measurement.endedAt, format: .dateTime.hour().minute())"
                            )
                        }
                    }
                    Button("Measure for \(Self.measureDuration) Seconds") {
                        // `Task { }` starts work that outlives this click. It is not tied to the
                        // view's `.task`, so hiding the window does not cancel it.
                        Task { await measure() }
                    }
                    .disabled(isMeasuring)
                    Text(
                        "Hides this window, samples CPU and memory for \(Self.measureDuration) seconds with nothing drawing, then shows it again."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .task { await refreshEverySecond() }
        }

        /// Once a second: a CPU and memory sample, and a fresh database snapshot if anything was
        /// written. Runs until the tab or the window goes away.
        private func refreshEverySecond() async {
            var previous = ProcessSample.current()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let sample = ProcessSample.current()
                // While the panel is open, or Measure is running, the display is left alone: no
                // queries and no re-rendering. The sample is still taken (a microsecond) so the
                // next CPU figure covers one second, not the whole pause.
                if model.isPanelVisible || isMeasuring {
                    previous = sample
                    continue
                }
                cpuPercent = sample.cpuPercent(since: previous)
                footprint = sample.footprint
                previous = sample
                do {
                    // `newestLimit: 0`: this tab needs the counts and sizes, not the rows.
                    if let fresh = try await inspector.snapshot(
                        ifChangedSince: snapshot?.dataVersion, newestLimit: 0)
                    {
                        snapshot = fresh
                    }
                } catch {
                    self.error = "Could not read the database: \(error.localizedDescription)"
                }
            }
        }

        /// Hides the window, samples for `measureDuration` seconds, shows it again with the
        /// result. The window is only ordered off screen, not closed, so this view and its state
        /// stay alive underneath.
        private func measure() async {
            let window = NSApplication.shared.windows.first { $0.title == DeveloperWindow.title }
            isMeasuring = true
            window?.orderOut(nil)
            let start = ProcessSample.current()
            var peak = start.footprint
            for _ in 0..<Self.measureDuration {
                try? await Task.sleep(for: .seconds(1))
                peak = max(peak, ProcessSample.current().footprint)
            }
            let end = ProcessSample.current()
            measurement = Measurement(
                cpuPercent: end.cpuPercent(since: start), peakFootprint: peak, endedAt: .now)
            isMeasuring = false
            window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
        }

        /// "1.2 MB" style text, or a dash before the first reading.
        private func bytes(_ count: Int?) -> String {
            guard let count else { return "–" }
            return Int64(count).formatted(.byteCount(style: .memory))
        }

        /// "0.3%" style text, or a dash before the first reading.
        private func percent(_ value: Double?) -> String {
            guard let value else { return "–" }
            return (value / 100).formatted(.percent.precision(.fractionLength(1)))
        }
    }
#endif
