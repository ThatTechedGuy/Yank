// ClipSystem is the "outer ring" that talks to macOS: NSPasteboard (the clipboard), NSWorkspace
// (which app is in front), CGEvent (pressing ⌘V), Vision (text in images) and so on.
//
// ClipCore declares small protocols (interfaces) for these, called ports. ClipSystem provides the
// real implementations; tests provide fakes. ≈ declaring `interface Clipboard` in a TS domain
// module and implementing it in a separate platform module, or an Android domain/data split.
//
// The adapters arrive from stage 1. Swift needs at least one source file per module, so this
// file only holds the module's place until then.
