import Foundation

/// Coalesces a burst of edits into one disk write (#91, #197).
///
/// Every keystroke in a caption or blog body used to serialise the whole events
/// store, so the cost scaled with how many events Dan has rather than with the
/// size of the edit, and a crash landing mid write is exactly the case that
/// leaves the store unreadable. It was found while diagnosing #196, where the
/// app really did die during an active editing session.
///
/// Only the DISK write is delayed. Callers update their in-memory state first
/// and hand the finished value here, so nothing ever reads stale text while a
/// write is pending; the worst case is a write that has not happened yet.
///
/// The pending value is written on teardown as well as on a pause, because the
/// review screen remounts whenever Dan switches events, and a debounce that
/// silently dropped his last sentence would be worse than the problem it
/// solves.
///
/// Deliberately not `@MainActor`: the write has to be callable from `deinit`,
/// which cannot hop to an actor. `write` is therefore expected to be a plain
/// disk write (`EventStore.save`, which is atomic) rather than anything that
/// touches UI state.
final class DebouncedStoreWriter<Value: Sendable>: @unchecked Sendable {
    private let interval: TimeInterval
    private let write: @Sendable (Value) -> Void

    private let lock = NSLock()
    private var pending: Value?
    /// Bumped on every edit so a fired timer belonging to a superseded edit
    /// does nothing rather than writing an older value over a newer one.
    private var generation: UInt64 = 0

    init(interval: TimeInterval = 0.6, write: @escaping @Sendable (Value) -> Void) {
        self.interval = interval
        self.write = write
    }

    deinit {
        // Sole owner at this point, so no lock is needed and none may be taken.
        if let pending { write(pending) }
    }

    /// Record the newest value and restart the quiet period.
    func schedule(_ value: Value) {
        lock.lock()
        pending = value
        generation &+= 1
        let mine = generation
        lock.unlock()

        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.flush(ifStillAt: mine)
        }
    }

    /// Write immediately if anything is pending.
    ///
    /// Called by every path that ends an editing session (navigating away,
    /// generating, exporting, quitting) and by any immediate save, so a
    /// structural change can never be persisted ahead of the text edit that
    /// preceded it.
    func flush() {
        flush(ifStillAt: nil)
    }

    private func flush(ifStillAt expected: UInt64?) {
        lock.lock()
        if let expected, expected != generation {
            // A newer edit has already restarted the timer; that one writes.
            lock.unlock()
            return
        }
        let value = pending
        pending = nil
        lock.unlock()

        guard let value else { return }
        write(value)
    }

    /// True while an edit is waiting to be written.
    var hasPendingWrite: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending != nil
    }
}
