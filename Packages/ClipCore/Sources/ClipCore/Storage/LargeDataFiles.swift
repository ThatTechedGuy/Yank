import Foundation

// Clipboard data over `inlineLimit` lives in files here; the row keeps only the name. The Store
// writes a file before the row that points at it and deletes it only after that row is gone, so a
// crash leaves at worst a file nobody points at, which `sweep` removes at the next launch.
/// The folder of large clipboard data files.
struct LargeDataFiles: Sendable {
    /// Data larger than this (1 MB) is stored as a file instead of in the row.
    static let inlineLimit = 1_000_000

    let folder: URL

    init(folder: URL) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Writes one piece of data and returns the file's name. The name is random, so a new file
    /// never overwrites one a row still needs.
    func write(_ data: Data) throws -> String {
        let name = "\(UUID().uuidString).bin"
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

    /// Deletes every file in the folder that no row points at: leftovers of a crash between
    /// writing a file and committing its row, or between deleting a row and its file.
    func sweep(keeping names: Set<String>) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            // Anything that is not one of our ".bin" files (".DS_Store", a stray file) is left alone.
            if name.hasSuffix(".bin"), !names.contains(name) {
                Log.store.notice("removing orphan data file \(name, privacy: .public)")
                try delete([name])
            }
        }
    }
}
