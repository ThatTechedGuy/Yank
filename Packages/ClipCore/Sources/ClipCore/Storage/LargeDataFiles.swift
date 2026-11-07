import Foundation

// Where the big bytes live. Clipboard data up to 1 MB sits in the
// `clipboardItemData.data` column; anything larger (a 50 MB image, a long RTF) is written to a
// file here and the row keeps only its name in `largeDataFileName`. SQLite is fastest with small
// rows, so a list of ten thousand items can be read without ever touching the big ones.
//
// Layout: one flat folder of files named `<random UUID>.bin`. The name has nothing to do with
// the item on purpose: the Store writes a file *before* the database row that points at it and
// deletes an old file only *after* the row that pointed at it is gone. A crash in between can
// therefore leave a file nobody points at, never a row that points at a missing or half-written
// file. Files nobody points at are removed by `sweep` at the next launch. Random names mean a
// new file never overwrites one a row still needs.
//
// `FileManager` is Foundation's file API, ≈ Node's `fs`. Every call here is synchronous and
// blocks the thread it runs on. The Store calls `write`, `delete` and `sweep` from its `async`
// methods (off the main thread, except `sweep` in `Store.init`, which runs on whichever thread
// creates the Store: the main thread at launch in the app) and `read` from a database read block.
/// The folder of large clipboard data files.
struct LargeDataFiles: Sendable {
    /// Data larger than this (1 MB) is stored as a file instead of in the row.
    static let inlineLimit = 1_000_000

    let folder: URL

    init(folder: URL) throws {
        self.folder = folder
        // Make sure the folder exists before the first write. `withIntermediateDirectories: true`
        // is `mkdir -p`: it creates missing parents and does not fail if the folder is there.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Writes one piece of data under a fresh random name and returns that name. The Store
    /// keeps it in the row's `largeDataFileName` and passes it back to `read` and `delete`.
    func write(_ data: Data) throws -> String {
        let name = "\(UUID().uuidString).bin"
        // `.atomic` writes to a temporary file and renames it into place, so a crash mid-write
        // leaves no half-written file under this name: either the whole file is there or none.
        try data.write(to: folder.appending(path: name), options: .atomic)
        return name
    }

    /// Reads back one file by the name `write` returned. Loads the whole file into memory.
    func read(_ name: String) throws -> Data {
        try Data(contentsOf: folder.appending(path: name))
    }

    /// Deletes the named files. A name that is already gone is not an error: the sweep or an
    /// earlier crash may have removed it.
    func delete(_ names: [String]) throws {
        for name in names {
            let url = folder.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Deletes every file in the folder that no row points at. Those are leftovers of a crash
    /// between writing a file and committing its row, or between deleting a row and its file.
    /// The Store calls this once, when it opens.
    func sweep(keeping names: Set<String>) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            // Only our own ".bin" files are touched. Anything else (".DS_Store", a stray file)
            // is not ours and is left alone.
            if name.hasSuffix(".bin"), !names.contains(name) {
                Log.store.notice("removing orphan data file \(name, privacy: .public)")
                try delete([name])
            }
        }
    }
}
