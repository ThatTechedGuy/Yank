// `os` is Apple's low-level system module; we use it only for Logger, the unified logging system.
// Unified logging is the Mac's Logcat: every app writes to one system log, tagged with a
// "subsystem" (≈ an Android log tag namespace) and a "category" (≈ the tag itself).
// Read our logs in Console.app by searching for the subsystem, or in Terminal:
//     log stream --predicate 'subsystem == "com.thattechedguy.Yank"' --info
import os

// `///` (three slashes) is a documentation comment, like `/** ... */` JSDoc. Xcode shows it when
// you Option-click a name (Quick Help).
//
// `public` makes a name visible outside this module (≈ `export`). Swift's default is `internal`,
// meaning visible anywhere inside the same module only.
//
// An `enum` with no cases can't be instantiated, so it works as a pure namespace for static
// members. ≈ a TS `namespace`, or a Kotlin `object` / Java class with a private constructor.
/// The app's loggers, one per area. Read them in Console.app by filtering on the subsystem.
public enum Log {
    // `static let` = a constant that belongs to the type, not to an instance (≈ Java `static final`).
    // The type (String) is inferred from the value, like `const x = "..."` in TS.
    /// The subsystem every Yank log uses: the app's bundle id.
    public static let subsystem = "com.thattechedguy.Yank"

    // Usage elsewhere: `Log.capture.info("saved item \(id)")`.
    // `\(...)` inside a string is interpolation, ≈ `${...}` in a TS template literal. Logger
    // treats interpolated values as private (shown as <private>) unless marked `privacy: .public`,
    // so clipboard contents never leak into the system log by accident.

    /// Noticing and saving copies.
    public static let capture = Logger(subsystem: subsystem, category: "capture")
    /// The database and the format files on disk.
    public static let store = Logger(subsystem: subsystem, category: "store")
    /// Putting items back on the clipboard and pressing ⌘V.
    public static let paste = Logger(subsystem: subsystem, category: "paste")
    /// Windows, the panel and the menu bar.
    public static let ui = Logger(subsystem: subsystem, category: "ui")
}
