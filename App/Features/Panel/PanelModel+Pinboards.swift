// The panel's pinboard actions, kept apart from the list and selection logic in
// PanelModel.swift: switching tabs (⌘[ ⌘]), pinning and unpinning the selected card (⌘P or
// the card's menu), and creating, renaming and deleting pinboards from the tab row. Each
// action is one Store call in a Task; the model never updates its own lists afterwards,
// because the live queries deliver the new state on their own (≈ a mutation that invalidates
// a query). An error is logged and the panel simply stays as it was.
import ClipCore
import SwiftUI

/// Why the "New Pinboard" name prompt is up: to create a pinboard, and, when a card was being
/// pinned and there was no pinboard to put it on, to pin that card to the new one.
struct NewPinboardPrompt: Hashable {
    /// The card to pin once the pinboard exists, or nil to only create it.
    var itemIdToPin: Int64?
}

extension PanelModel {
    /// The tabs in order: History first, then the pinboards.
    var tabs: [ItemList] { [.history] + pinboards.map { .pinboard(id: $0.id) } }

    /// ⌘]: the tab to the right, round to History after the last pinboard.
    func selectNextTab() { moveTab(by: 1) }

    /// ⌘[: the tab to the left, round to the last pinboard from History.
    func selectPreviousTab() { moveTab(by: -1) }

    private func moveTab(by step: Int) {
        let tabs = tabs
        guard let index = tabs.firstIndex(of: filter.list) else { return }
        // `%` can go negative in Swift, so add the count first to wrap backwards too.
        filter.list = tabs[(index + step + tabs.count) % tabs.count]
    }

    /// The pinboard the panel is on, nil on History.
    var currentPinboard: Pinboard? {
        guard case .pinboard(let id) = filter.list else { return nil }
        return pinboards.first { $0.id == id }
    }

    /// The search box's placeholder, naming the list the search looks in.
    var searchPrompt: String {
        currentPinboard.map { "Search “\($0.name)”…" } ?? "Search history…"
    }

    /// The selected card's item, if one is selected.
    var selectedItem: ClipboardItem? { items.first { $0.id == selectedId } }

    /// ⌘P: puts the selected card on a pinboard, or takes it off the one it is on. With one
    /// pinboard the card goes straight there; with several, a chooser opens on the card; with
    /// none, the name prompt opens and the card is pinned to the pinboard it creates.
    func togglePin() {
        guard let item = selectedItem else { return }
        if item.pinboardId != nil {
            unpin(item.id)
            return
        }
        switch pinboards.count {
        case 0: newPinboardPrompt = NewPinboardPrompt(itemIdToPin: item.id)
        case 1: pin(item.id, to: pinboards[0].id)
        default: pinChooserItemId = item.id
        }
    }

    /// Moves a card onto a pinboard. On the History tab it leaves the row; on the pinboard's
    /// tab it appears, both through the live list.
    func pin(_ itemId: Int64, to pinboardId: Int64) {
        pinChooserItemId = nil
        Task { [store] in
            do {
                try await store.pin(itemId: itemId, to: pinboardId)
            } catch {
                Log.ui.error("could not pin item \(itemId, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    /// Moves a card back to History.
    func unpin(_ itemId: Int64) {
        Task { [store] in
            do {
                try await store.unpin(itemId: itemId)
            } catch {
                Log.ui.error("could not unpin item \(itemId, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    /// Creates a pinboard from the prompt's name, pins the prompt's card to it if there is one,
    /// and switches to its tab, so the user sees where the card went. A blank name creates
    /// nothing; spaces around the name are dropped.
    func createPinboard(named name: String, for prompt: NewPinboardPrompt) {
        newPinboardPrompt = nil
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task { [store] in
            do {
                let pinboard = try await store.createPinboard(named: name)
                if let itemId = prompt.itemIdToPin {
                    try await store.pin(itemId: itemId, to: pinboard.id)
                }
                filter.list = .pinboard(id: pinboard.id)
            } catch {
                Log.ui.error("could not create a pinboard: \(error, privacy: .public)")
            }
        }
    }

    /// Gives a pinboard a new name; a blank one is ignored, so Rename can never leave a tab
    /// without a label.
    func renamePinboard(_ pinboard: Pinboard, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != pinboard.name else { return }
        Task { [store] in
            do {
                try await store.renamePinboard(id: pinboard.id, to: name)
            } catch {
                Log.ui.error(
                    "could not rename pinboard \(pinboard.id, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    /// Deletes a pinboard; its items go back to History (the Store does that). The tab row's
    /// live query drops the tab, and the model moves to History if that tab was showing.
    func deletePinboard(_ pinboard: Pinboard) {
        Task { [store] in
            do {
                try await store.deletePinboard(id: pinboard.id)
            } catch {
                Log.ui.error(
                    "could not delete pinboard \(pinboard.id, privacy: .public): \(error, privacy: .public)")
            }
        }
    }
}
