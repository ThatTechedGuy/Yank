// The panel's item actions: what the card's menu (right-click or ⌘K) can do to a card, and the
// small dialogs some of them open first. Each is one Store call in a Task and the live list
// shows the result; an error is logged and the panel stays as it was.
import AppKit
import ClipCore
import UniformTypeIdentifiers

/// A small dialog open on one card. `anchorId` is the card it is anchored to.
enum CardPrompt: Equatable {
    /// The actions menu, opened with ⌘K (right-click opens the same rows as a real menu).
    case actions(anchorId: Int64)
    /// The Rename box for one card.
    case rename(anchorId: Int64)
    /// "Delete N items?" for the selected cards; the lead card anchors it.
    case delete(ids: [Int64], anchorId: Int64)

    var anchorId: Int64 {
        switch self {
        case .actions(let id), .rename(let id), .delete(_, let id): id
        }
    }
}

/// Everything the actions menu offers, in menu order. One enum, so the right-click menu and
/// the ⌘K list show the same rows and the keyboard can walk them.
enum ItemAction: String, CaseIterable, Identifiable {
    case paste, pasteAsPlainText, copy, pinTo, addToStack, edit, rename, duplicate, share, openWith,
        showInFinder, delete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paste: "Paste"
        case .pasteAsPlainText: "Paste as Plain Text"
        case .copy: "Copy"
        case .pinTo: "Pin to…"
        case .addToStack: "Add to Stack"
        case .edit: "Edit"
        case .rename: "Rename…"
        case .duplicate: "Duplicate"
        case .share: "Share…"
        case .openWith: "Open With"
        case .showInFinder: "Show in Finder"
        case .delete: "Delete"
        }
    }

    /// Whether a separator goes above this row in the menu: paste rows, then organising, then
    /// editing, then leaving the app, then Delete on its own.
    var startsGroup: Bool { [.pinTo, .edit, .share, .delete].contains(self) }

    /// The rows this card gets: Show in Finder only for a file card, and Edit for text, links
    /// and images. A file is not Yank's to change, and a colour has nothing the editor can show.
    static func available(for item: ClipboardItem) -> [ItemAction] {
        allCases.filter { action in
            switch action {
            case .showInFinder: item.kind == .file
            case .edit: item.kind != .file && item.kind != .color
            default: true
            }
        }
    }
}

extension PanelModel {
    /// The lead card's menu, for ⌘K. Nothing selected: nothing opens.
    func openActions() {
        guard let id = selectedId else { return }
        prompt = .actions(anchorId: id)
    }

    /// Does one action on a card, for a menu row or Return on a ⌘K row. Paste, Copy and Delete
    /// act on the whole selection when the card is part of it. Pin to and Open With have their
    /// own submenus; from the keyboard they do the plain thing (⌘P's behaviour, the default
    /// app). Share needs its own button, so Return on it does nothing.
    func perform(_ action: ItemAction, on item: ClipboardItem) {
        prompt = nil
        let targets = selection.contains(item.id) ? selectedItems : [item]
        switch action {
        case .paste: paste(targets, plainText: false)
        case .pasteAsPlainText: paste(targets, plainText: true)
        case .copy: paste(targets, plainText: false, destination: .clipboardOnly)
        case .pinTo:
            selectedId = item.id
            togglePin()
        case .addToStack: addToStack(item)
        case .rename: prompt = .rename(anchorId: item.id)
        case .duplicate: duplicate(item)
        case .openWith: open(item, with: nil)
        case .showInFinder: showInFinder(item)
        case .delete: confirmDelete(of: targets)
        case .edit: openEditor(item)
        case .share: break
        }
    }

    /// ⌘E: the selected card in the editor. A card with no Edit row is left alone.
    func editSelected() {
        guard let item = selectedItem, ItemAction.available(for: item).contains(.edit) else { return }
        openEditor(item)
    }

    /// Delete (the key or the menu): asks first, naming the count, on the lead card.
    func confirmDelete(of items: [ClipboardItem]) {
        guard let anchor = items.first(where: { $0.id == selectedId }) ?? items.first else { return }
        prompt = .delete(ids: items.map(\.id), anchorId: anchor.id)
    }

    /// Deletes the cards the prompt named, after "Delete". The live list drops them in one go.
    func delete(ids: [Int64]) {
        prompt = nil
        Task { [store] in
            do {
                try await store.delete(ids: ids)
                refreshSearch()
            } catch {
                Log.ui.error(
                    "could not delete \(ids.count, privacy: .public) items: \(error.logDescription, privacy: .public)"
                )
            }
        }
    }

    /// Gives a card a name of the user's own, shown instead of its first line and found by
    /// search; a blank name takes it away again (the Store does the trimming).
    func rename(_ item: ClipboardItem, to title: String) {
        prompt = nil
        Task { [store] in
            do {
                try await store.rename(id: item.id, to: title)
                refreshSearch()
            } catch {
                Log.ui.error(
                    "could not rename item \(item.id, privacy: .public): \(error.logDescription, privacy: .public)"
                )
            }
        }
    }

    /// Makes a separate copy of the card at the top of the list and selects it.
    func duplicate(_ item: ClipboardItem) {
        Task { [store] in
            do {
                if let copy = try await store.duplicate(id: item.id) {
                    selectedId = copy.id
                    refreshSearch()
                }
            } catch {
                Log.ui.error(
                    "could not duplicate item \(item.id, privacy: .public): \(error.logDescription, privacy: .public)"
                )
            }
        }
    }

    /// Finder, with the card's file selected. Only a file card has this row.
    func showInFinder(_ item: ClipboardItem) {
        Task { [store] in
            guard let url = try? await store.quickLookFile(for: item) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// The apps that can open what the card holds, for the Open With rows: by the file's
    /// extension for a file card, by the kind of content for the rest.
    func appsThatOpen(_ item: ClipboardItem) -> [URL] {
        let type: UTType
        switch item.kind {
        case .file:
            // The card's text lists the file names, one per line; the first one's extension
            // says what kind of file it is.
            let name = item.cardText.split(separator: "\n").first.map(String.init) ?? ""
            type = UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        case .image: type = .png
        case .link:
            guard let url = URL(string: item.cardText) else { return [] }
            return NSWorkspace.shared.urlsForApplications(toOpen: url)
        case .text, .color: type = .plainText
        }
        return NSWorkspace.shared.urlsForApplications(toOpen: type)
    }

    /// Opens the card in the chosen app, or in the default app for it when `app` is nil: a
    /// file card's file, a link's address, and for the rest the same temporary file Quick
    /// Look uses, so the app gets a real document.
    func open(_ item: ClipboardItem, with app: URL?) {
        prompt = nil
        Task { [store] in
            let url: URL?
            if item.kind == .link {
                // The saved address, not the card's text, which stops at 200 characters.
                url = (try? await store.data(for: item.id)).flatMap { URL(string: $0.linkAddress) }
            } else {
                url = try? await store.quickLookFile(for: item)
            }
            guard let url else { return }
            if let app {
                _ = try? await NSWorkspace.shared.open(
                    [url], withApplicationAt: app, configuration: .init())
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Notes whether a file card's file is still there. Each file card calls this as it comes
    /// on screen, and a refused paste calls it for the cards it tried.
    func checkFile(of item: ClipboardItem) async {
        guard item.kind == .file, let data = try? await store.data(for: item.id) else { return }
        if await data.hasMissingFile() {
            missingFileIds.insert(item.id)
        } else {
            missingFileIds.remove(item.id)
        }
    }
}
