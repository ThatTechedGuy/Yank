// Reads this launch's log lines back from the system log. Each read is a request to `logd` that
// takes a second or more, so reads are few (see LogsView), incremental, and on an actor: off the
// main thread, with `OSLogStore`, which is not safe to share between threads, kept inside it.
#if DEBUG
    import ClipCore
    import OSLog

    /// One line of the app's log, as the Logs tab shows it.
    struct LogLine: Identifiable, Sendable {
        let id = UUID()
        let date: Date
        let level: OSLogEntryLog.Level
        let category: String
        /// The message with interpolated values already filled in; private values show as
        /// `<private>`, exactly as in Console.app, so clipboard contents never appear here.
        let message: String

        var levelName: String {
            switch level {
            case .debug: "debug"
            case .info: "info"
            case .notice: "notice"
            case .error: "error"
            case .fault: "fault"
            default: "?"
            }
        }
    }

    actor LogReader {
        private let store: OSLogStore
        /// When the newest line returned so far was logged; the next read starts there.
        private var newest: Date?

        init() throws {
            // The one scope the sandbox allows: this process's entries, so this launch only.
            store = try OSLogStore(scope: .currentProcessIdentifier)
        }

        /// The app's log lines since the last call (all of them on the first call), oldest
        /// first, at `.info` level and above. Debug lines are never returned by the store.
        func newLines() throws -> [LogLine] {
            // The store has no "after" position, so the newest line already seen comes back once
            // more and is skipped below.
            let position = newest.map { store.position(date: $0) }
            let entries = try store.getEntries(
                at: position,
                matching: NSPredicate(format: "subsystem == %@", Log.subsystem))
            var lines: [LogLine] = []
            for case let entry as OSLogEntryLog in entries {
                // shortcut: a new line with the same timestamp as `newest` is dropped too; count
                // the lines seen at that instant if the Logs tab is ever seen to miss one.
                if let newest, entry.date <= newest { continue }
                lines.append(
                    LogLine(
                        date: entry.date, level: entry.level, category: entry.category,
                        message: entry.composedMessage))
            }
            if let last = lines.last { newest = last.date }
            return lines
        }
    }
#endif
