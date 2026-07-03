import os

/// Bounds the number of concurrently-running subdirectory-scanning tasks.
/// Lock-based rather than actor-based for the same hot-path reason as
/// `InodeTracker` — this is checked once per directory encountered across
/// many concurrent workers.
final class WorkerSlotPool: @unchecked Sendable {
    private struct State {
        var active: Int
        let max: Int
    }
    private let lock: OSAllocatedUnfairLock<State>

    init(max: Int) {
        lock = OSAllocatedUnfairLock(initialState: State(active: 0, max: max))
    }

    /// Attempts to claim a slot; returns `false` (without side effects) if
    /// the pool is already at capacity.
    func tryAcquire() -> Bool {
        lock.withLock { state in
            guard state.active < state.max else { return false }
            state.active += 1
            return true
        }
    }

    func release() {
        lock.withLock { state in state.active -= 1 }
    }
}
