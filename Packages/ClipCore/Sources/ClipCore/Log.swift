// `os` is Apple's low-level system module; we use it only for Logger, the unified logging system.
// Unified logging is the Mac's Logcat: every app writes to one system log, tagged with a
// "subsystem" (≈ an Android log tag namespace) and a "category" (≈ the tag itself).
// Read our logs in Console.app by searching for the subsystem, or in Terminal:
//     log stream --predicate 'subsystem == "com.thattechedguy.Yank"' --info
import Foundation
import os

// One place that defines every logger Yank uses, so each file logs the same way and you can filter
// the whole app's logs with one subsystem, or one area with its category. `public` makes it
// visible to the app and ClipSystem too (≈ `export`; Swift's default is `internal`, visible only
// inside the same module). An `enum` with no cases can't be instantiated, so it works as a pure
// namespace for static members. ≈ a TS `namespace`, or a Kotlin `object` / Java class with a
// private constructor. (`///` is a documentation comment, like `/** ... */` JSDoc; Xcode shows it
// when you Option-click a name.)
/// The app's loggers, one per area. Read them in Console.app by filtering on the subsystem.
public enum Log {
    // The bundle id is Apple's convention for the subsystem, and it is what you type into
    // Console.app's filter to see only Yank. (`static let` = a constant that belongs to the type,
    // not to an instance, ≈ Java `static final`; the String type is inferred from the value.)
    /// The subsystem every Yank log uses: the app's bundle id.
    public static let subsystem = "com.thattechedguy.Yank"

    // Usage elsewhere: `Log.capture.info("saved item \(id)")`.
    // `\(...)` inside a string is interpolation, ≈ `${...}` in a TS template literal. Logger
    // treats interpolated values as private (shown as <private>) unless marked `privacy: .public`,
    // so clipboard contents never leak into the system log by accident. Only mark a value public
    // when it cannot contain what the user copied.

    /// Noticing and saving copies.
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    /// The database and the format files on disk.
    public static let store = Logger(subsystem: subsystem, category: "store")
    /// Putting items back on the clipboard and pressing ⌘V.
    public static let paste = Logger(subsystem: subsystem, category: "paste")
    /// Windows, the panel and the menu bar.
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    /// Every SQL statement the database runs, with its duration. Debug builds only: the Store
    /// installs the trace that writes here, so a release build never logs a statement.
    public static let sql = Logger(subsystem: subsystem, category: "sql")

    // Timing markers: a named interval with a start and an end, so a tool can measure how long
    // something took (opening the panel, a search). ≈ `performance.mark`/`measure` on the web,
    // or Android's `Trace.beginSection`. Instruments draws them on a timeline; from Terminal,
    // `log show --signpost --predicate 'subsystem == "com.thattechedguy.Yank"'` lists them.
    // `TimingSignposter` wraps Apple's `OSSignposter` so a debug build can also show the last
    // durations in its Developer window; see that file.
    /// Timing markers, for measuring the app against its speed limits.
    public static let timing = TimingSignposter(subsystem: subsystem, category: "timing")
}

// An error's full text can hold what the user copied: a failed link preview's error carries the
// link's address, a file error carries the file's path. Errors are logged at the `.error` level,
// which macOS keeps on disk, so in a release build only the error's kind goes into the log.
// `extension Error` adds a member to every error type, ≈ adding a method to an interface in
// Kotlin with an extension function.
extension Error {
    /// What a log line may say about this error, marked public: in debug builds the full
    /// message, in release builds only its domain and code, such as "NSURLErrorDomain -1001".
    public var logDescription: String {
        #if DEBUG
            String(describing: self)
        #else
            // Every Swift error converts to NSError, Foundation's error type, which always has
            // a domain (for a Swift error, its type's name) and a number (for an enum, the case).
            let error = self as NSError
            return "\(error.domain) \(error.code)"
        #endif
    }
}
