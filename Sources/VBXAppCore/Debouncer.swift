import Foundation

/// Somewhere to run deferred work, injected so the debounce can be tested
/// against a virtual clock instead of wall-clock sleeps.
protocol DebounceScheduler: AnyObject {
    /// Runs `work` no earlier than `delay` from now. Calling the returned
    /// closure cancels it if it has not started.
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> () -> Void
}

/// Runs deferred work on a serial dispatch queue.
final class QueueDebounceScheduler: DebounceScheduler {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) { self.queue = queue }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> () -> Void {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
}

/// Trailing-edge debounce: `action` runs once `window` has passed with no
/// further `signal()`. Each signal cancels the pending run and starts the
/// window again, so a burst of signals closer together than `window` runs the
/// action exactly once, after the last of them.
///
/// Not thread-safe: signal, cancel and the scheduler's work must all happen on
/// one serial context — ``FileWatchService`` confines them to its queue.
final class Debouncer {
    let window: TimeInterval
    private let scheduler: DebounceScheduler
    private let action: () -> Void
    private var cancelPending: (() -> Void)?

    init(window: TimeInterval, scheduler: DebounceScheduler, action: @escaping () -> Void) {
        self.window = window
        self.scheduler = scheduler
        self.action = action
    }

    /// True while a run is scheduled and has not yet happened.
    var isPending: Bool { cancelPending != nil }

    func signal() {
        cancelPending?()
        cancelPending = scheduler.schedule(after: window) { [weak self] in
            guard let self else { return }
            self.cancelPending = nil
            self.action()
        }
    }

    func cancel() {
        cancelPending?()
        cancelPending = nil
    }
}
