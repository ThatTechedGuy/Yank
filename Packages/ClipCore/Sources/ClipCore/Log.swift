// To read the logs from Terminal:
//     log stream --predicate 'subsystem == "com.thattechedguy.Yank"' --info
import Foundation
import os

/// The app's loggers, one per area. Read them in Console.app by filtering on the subsystem.
public enum Log {
    /// The subsystem every Yank log uses: the app's bundle id.
    public static let subsystem = "com.thattechedguy.Yank"

    // Logger shows interpolated values as <private> unless marked `privacy: .public`, so clipboard
    // contents never leak into the system log by accident. Only mark a value public when it cannot
    // contain what the user copied.

    /// Noticing and saving copies.
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    /// The database and the large-data files on disk.
    public static let store = Logger(subsystem: subsystem, category: "store")
    /// Putting items back on the clipboard and pressing ⌘V.
    public static let paste = Logger(subsystem: subsystem, category: "paste")
    /// Windows, the panel and the menu bar.
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    /// Every SQL statement the database runs, with its duration. Debug builds only: the Store
    /// installs the trace that writes here, so a release build never logs a statement.
    public static let sql = Logger(subsystem: subsystem, category: "sql")

    // To list the markers from Terminal:
    //     log show --signpost --predicate 'subsystem == "com.thattechedguy.Yank"'
    /// Timing markers, for measuring the app against its speed limits.
    public static let timing = TimingSignposter(subsystem: subsystem, category: "timing")
}

// An error's full text can hold what the user copied: a failed link preview's error carries the
// link's address, a file error carries the file's path. Errors are logged at the `.error` level,
// which macOS keeps on disk, so in a release build only the error's kind goes into the log.
extension Error {
    /// What a log line may say about this error, marked public: in debug builds the full
    /// message, in release builds only its domain and code, such as "NSURLErrorDomain -1001".
    public var logDescription: String {
        #if DEBUG
            String(describing: self)
        #else
            let error = self as NSError
            return "\(error.domain) \(error.code)"
        #endif
    }
}
