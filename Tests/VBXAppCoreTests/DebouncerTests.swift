import Foundation
import Testing

@testable import VBXAppCore

/// A virtual clock: work runs only when the test advances time past its due
/// date, so the debounce is asserted without any wall-clock sleep.
private final class ManualScheduler: DebounceScheduler {
    private struct Job {
        let id: Int
        let due: TimeInterval
        let work: () -> Void
    }

    private(set) var now: TimeInterval = 0
    private var jobs: [Job] = []
    private var nextID = 0

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> () -> Void {
        let id = nextID
        nextID += 1
        jobs.append(Job(id: id, due: now + delay, work: work))
        return { [weak self] in self?.jobs.removeAll { $0.id == id } }
    }

    /// Moves the clock forward, running each job that falls due on the way in
    /// due order.
    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let next = jobs.filter({ $0.due <= target }).min(by: { $0.due < $1.due }) {
            jobs.removeAll { $0.id == next.id }
            now = next.due
            next.work()
        }
        now = target
    }
}

@Test("A burst closer together than the window runs the action once, after the last signal")
func debouncerCollapsesBurst() {
    let clock = ManualScheduler()
    var fired: [TimeInterval] = []
    let debouncer = Debouncer(window: 0.15, scheduler: clock) { fired.append(clock.now) }

    for _ in 0..<4 {
        debouncer.signal()
        clock.advance(by: 0.02)
    }
    #expect(fired.isEmpty, "fired inside the window")
    #expect(debouncer.isPending)

    clock.advance(by: 1)
    #expect(fired.count == 1)
    // Trailing edge: the window is measured from the last signal (at 0.06).
    #expect(abs((fired.first ?? 0) - 0.21) < 1e-9)
    #expect(!debouncer.isPending)
}

@Test("A burst whose gaps reach the window is not collapsed")
func debouncerSeparatesSpacedSignals() {
    // This is what happened to the real-FSEvents test under load: 20 ms sleeps
    // overshot the window, and each write fired on its own — correctly.
    let clock = ManualScheduler()
    var fired = 0
    let debouncer = Debouncer(window: 0.15, scheduler: clock) { fired += 1 }

    for _ in 0..<4 {
        debouncer.signal()
        clock.advance(by: 0.15)
    }
    #expect(fired == 4)
}

@Test("A signal just inside the window restarts it")
func debouncerRestartsWindow() {
    let clock = ManualScheduler()
    var fired = 0
    let debouncer = Debouncer(window: 0.15, scheduler: clock) { fired += 1 }

    debouncer.signal()
    clock.advance(by: 0.149)
    debouncer.signal()
    clock.advance(by: 0.149)
    #expect(fired == 0, "the second signal must restart the window, not join the first's")
    clock.advance(by: 0.001)
    #expect(fired == 1)
}

@Test("Cancelling drops the pending run")
func debouncerCancels() {
    let clock = ManualScheduler()
    var fired = 0
    let debouncer = Debouncer(window: 0.15, scheduler: clock) { fired += 1 }

    debouncer.signal()
    debouncer.cancel()
    clock.advance(by: 1)
    #expect(fired == 0)
    #expect(!debouncer.isPending)
}
