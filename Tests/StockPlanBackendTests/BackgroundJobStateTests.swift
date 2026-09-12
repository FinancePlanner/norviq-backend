import Foundation
@testable import StockPlanBackend
import Testing

/// The contract every repeating background job depends on for a clean shutdown.
///
/// The failure this prevents is not a test assertion but a process death: a run
/// that outlives its `Application` reaches `app.db`, which force-unwraps a nil
/// database once the app is torn down, killing the whole test binary.
@Suite("BackgroundJobState")
struct BackgroundJobStateTests {
    @Test("A run can be claimed and released")
    func claimAndRelease() {
        let state = BackgroundJobState()

        #expect(state.begin())
        state.finish()
        #expect(state.begin(), "a released claim can be taken again")
    }

    /// Ticks must not overlap: a slow run should cause the next tick to be
    /// skipped, not to start a second concurrent run against the same tables.
    @Test("A second run cannot start while one is in flight")
    func noOverlappingRuns() {
        let state = BackgroundJobState()

        #expect(state.begin())
        #expect(state.begin() == false, "overlapping ticks must be refused")
    }

    /// The first of the three properties: a timer tick firing during teardown
    /// must not open a fresh database query.
    @Test("No run may start once shutdown has begun")
    func shutdownRefusesNewRuns() {
        let state = BackgroundJobState()

        state.stopAcceptingRuns()

        #expect(state.begin() == false)
    }

    /// The third property, and the one every job was missing. Cancellation is
    /// cooperative, so a run suspended in a database await keeps going; shutdown
    /// has to wait for it.
    @Test("Shutdown waits for the run in flight")
    func shutdownDrainsInFlightRun() async {
        let state = BackgroundJobState()
        let started = AsyncSignal()
        let finished = Mutexed(false)

        #expect(state.begin())
        let task = Task {
            await started.signal()
            try? await Task.sleep(for: .milliseconds(300))
            finished.set(true)
            state.finish()
        }
        state.track(task: task)
        await started.wait()

        await state.stopAndDrain()

        #expect(finished.get(), "stopAndDrain returned while the run was still going")
    }

    @Test("Draining with nothing in flight returns immediately")
    func drainWithoutRunIsSafe() async {
        let state = BackgroundJobState()
        await state.stopAndDrain()
        #expect(state.begin() == false)
    }

    /// A job whose task is registered after shutdown has already run — a real
    /// ordering during teardown — must not be left running.
    @Test("A task tracked after shutdown is cancelled immediately")
    func taskTrackedAfterShutdownIsCancelled() async {
        let state = BackgroundJobState()
        state.stopAcceptingRuns()

        let observed = Mutexed(false)
        let task = Task {
            try? await Task.sleep(for: .seconds(5))
            observed.set(Task.isCancelled)
        }
        state.track(task: task)
        await task.value

        #expect(observed.get(), "the late task should have been cancelled")
    }
}

/// One-shot async signal, so a test waits for the task to actually start rather
/// than sleeping and hoping.
private actor AsyncSignal {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignalled = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func wait() async {
        if isSignalled {
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class Mutexed<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
