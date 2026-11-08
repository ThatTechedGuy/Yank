// Reads this launch's log lines back from the system log. macOS keeps every app's log lines in
// one system-wide store (the one Console.app shows) and `OSLogStore` is the API that reads it.
// From inside the sandbox an app may only read its own process's entries, and even then each
// read is a request to the `logd` daemon that takes a second or more to answer, while costing
// this process almost no CPU. So reads are few (see LogsView), always off the main thread, and
// each one asks only for what is new since the last read.
//
// It is an `actor`: its methods run one at a time on a background thread, so the slow read
// never touches the main thread, and `OSLogStore`, which is not safe to share between threads,
// never leaves it. ≈ a class whose every method is async and internally serialised.
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

        /// The level as a word.
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
            // `.currentProcessIdentifier`: only this process's entries, the one scope the
            // sandbox allows. It only sees the current launch.
            store = try OSLogStore(scope: .currentProcessIdentifier)
        }

        /// The app's log lines since the last call (all of them on the first call), oldest
        /// first, at `.info` level and above. Debug lines are never returned by the store.
        func newLines() throws -> [LogLine] {
            // Start reading at the newest line already seen (the store has no "after" position,
            // so that line comes back once more and is skipped below).
            let position = newest.map { store.position(date: $0) }
            let entries = try store.getEntries(
                at: position,
                matching: NSPredicate(format: "subsystem == %@", Log.subsystem))
            var lines: [LogLine] = []
            // `for case let entry as OSLogEntryLog in` keeps only the entries that are log lines
            // (not signposts or activities) and gives them that type.
            for case let entry as OSLogEntryLog in entries {
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
