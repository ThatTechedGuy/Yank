import Foundation

// The paste stack: a queue of items to paste one after another. Turn it on from the menu bar,
// copy A, B and C, then press "paste next" three times in another app and A, B, C come out in
// that order. It is a plain value with three states, Off, On and empty, On with items waiting,
// and a method for each way of moving between them; the app keeps one of these and the menu
// bar draws its count. ≈ a discriminated union in TS: `{ kind: 'off' } | { kind: 'on', queue }`.
//
// The queue holds whole items, not ids, so "paste next" can hand the item straight to the
// paste service and the menu can list what is waiting without a database read.
/// Whether the paste stack is on, and the items waiting in it, oldest first.
public enum PasteStack: Equatable, Sendable {
    /// Copies go to the history only.
    case off
    /// Copies also queue here, in the order they were made. Empty when nothing is waiting.
    case on(queue: [ClipboardItem])

    public var isOn: Bool {
        if case .on = self { return true }
        return false
    }

    /// The items waiting, oldest first; empty while off.
    public var queue: [ClipboardItem] {
        if case .on(let queue) = self { return queue }
        return []
    }

    /// Switches the stack on with an empty queue. Already on: nothing changes.
    public mutating func turnOn() {
        if case .off = self { self = .on(queue: []) }
    }

    /// Switches the stack off and drops the queue. The items stay in the history.
    public mutating func turnOff() {
        self = .off
    }

    /// Adds a copy to the end of the queue. While the stack is off nothing happens, so the
    /// capture loop can call this on every save without checking first.
    public mutating func add(_ item: ClipboardItem) {
        guard case .on(var queue) = self else { return }
        queue.append(item)
        self = .on(queue: queue)
    }

    /// Takes the oldest item off the queue and returns it, or nil when the queue is empty or
    /// the stack is off. The item leaves the queue whether or not the paste that follows can
    /// press ⌘V, so a missing Accessibility permission never jams the stack.
    public mutating func popNext() -> ClipboardItem? {
        guard case .on(var queue) = self, !queue.isEmpty else { return nil }
        let next = queue.removeFirst()
        self = .on(queue: queue)
        return next
    }
}
