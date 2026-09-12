import Foundation
import NIOCore
import Vapor

/// Lifecycle state shared by the repeating background jobs in `configure.swift`.
///
/// Every one of those jobs schedules a `RepeatedTask` whose closure spawns a
/// `Task` that queries `app.db`. Cancelling only the timer leaves a run already
/// in flight to carry on into an `Application` whose databases have been torn
/// down — and `app.db` force-unwraps there, so the process dies outright rather
/// than throwing. That is what took down the whole test suite with
/// `Fatal error: Unexpectedly found nil` and signal 4.
///
/// Getting this right needs three things, and each job was doing at most two:
///
/// 1. Refuse to start a run once shutdown has begun, so a timer tick that fires
///    mid-teardown does not open a fresh database query.
/// 2. Cancel the run in flight.
/// 3. **Wait** for it. Cancellation is cooperative, and a run suspended inside a
///    database await does not stop just because it was cancelled.
///
/// Owning all three here means a job gets them by construction instead of by
/// remembering. Jobs delegate `shutdown` to ``stopAcceptingRuns()`` and
/// `shutdownAsync` to ``stopAndDrain()``.
final class BackgroundJobState: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: RepeatedTask?
    private var inFlight: Task<Void, Never>?
    private var isRunning = false
    private var isShutDown = false

    init() {}

    /// Claims the right to start a run. `false` means either a previous run is
    /// still going (ticks must not overlap) or the job is shutting down.
    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning, !isShutDown else { return false }
        isRunning = true
        return true
    }

    /// Releases the claim taken by ``begin()``. Call from a `defer` so it runs
    /// even when the job body throws or is cancelled.
    func finish() {
        lock.lock()
        isRunning = false
        lock.unlock()
    }

    func set(scheduled task: RepeatedTask) {
        lock.lock()
        let alreadyShutDown = isShutDown
        if !alreadyShutDown {
            scheduled = task
        }
        lock.unlock()
        // Booted into a shutdown that had already happened; don't leave a timer
        // running with nobody to cancel it.
        if alreadyShutDown {
            task.cancel()
        }
    }

    /// Records the run so shutdown can wait for it.
    func track(task: Task<Void, Never>) {
        lock.lock()
        let alreadyShutDown = isShutDown
        if !alreadyShutDown {
            inFlight = task
        }
        lock.unlock()
        if alreadyShutDown {
            task.cancel()
        }
    }

    /// Synchronous shutdown: stop the timer, refuse further runs, and cancel the
    /// one in flight. It cannot wait — `LifecycleHandler.shutdown` is not async —
    /// so prefer ``stopAndDrain()`` wherever an async context exists.
    func stopAcceptingRuns() {
        lock.lock()
        isShutDown = true
        scheduled?.cancel()
        scheduled = nil
        let task = inFlight
        lock.unlock()
        task?.cancel()
    }

    /// Full shutdown: stop accepting runs, then wait for the in-flight run to
    /// actually finish touching the application.
    func stopAndDrain() async {
        stopAcceptingRuns()
        while let task = takeInFlight() {
            task.cancel()
            await task.value
        }
    }

    /// Separated so the lock is never held across a suspension point: `NSLock`
    /// is unavailable from async contexts, and holding one over an await risks
    /// unlocking from a different thread than locked it.
    private func takeInFlight() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        let task = inFlight
        inFlight = nil
        return task
    }
}
