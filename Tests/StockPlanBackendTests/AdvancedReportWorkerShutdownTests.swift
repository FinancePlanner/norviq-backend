import Foundation
@testable import StockPlanBackend
import Testing

/// The worker ticks every 10 seconds from 2 seconds after boot, so in a test run
/// it is firing constantly against short-lived `Application`s.
///
/// Its shutdown used to cancel only the repeated timer, leaving any run already
/// in flight to carry on. That run then reached `app.db` on an application whose
/// databases had been torn down, and Fluent force-unwraps there — so the whole
/// test process died with `Fatal error: Unexpectedly found nil` and signal 4,
/// taking hundreds of unrelated tests with it.
///
/// These tests pin the two properties that stop that: shutdown refuses to let
/// new work start, and it waits for work already running.
@Suite("AdvancedReportWorker shutdown")
struct AdvancedReportWorkerShutdownTests {
    @Test("Shutdown refuses any further runs")
    func shutdownRefusesFurtherRuns() async {
        let worker = AdvancedReportWorker(gotenbergBaseURL: "http://unused:3000")

        // Accepting work before shutdown is the baseline; without it the test
        // could pass simply because the worker never accepts anything.
        #expect(worker.beginForTesting())
        worker.finishForTesting()

        await worker.shutdownForTesting()

        #expect(
            worker.beginForTesting() == false,
            "a tick that fires after shutdown must not start a run that would touch app.db"
        )
    }

    @Test("Shutdown waits for a run already in flight")
    func shutdownWaitsForInFlightRun() async {
        let worker = AdvancedReportWorker(gotenbergBaseURL: "http://unused:3000")

        let started = AsyncSignal()
        let finished = Mutexed(false)

        #expect(worker.beginForTesting())
        let task = Task {
            await started.signal()
            // Stands in for a real run still querying the database.
            try? await Task.sleep(for: .milliseconds(300))
            finished.set(true)
            worker.finishForTesting()
        }
        worker.trackForTesting(task: task)
        await started.wait()

        await worker.shutdownForTesting()

        #expect(
            finished.get(),
            "shutdown returned while a run was still using the application"
        )
    }
}

/// One-shot async signal, so the test can wait for the task to actually start
/// rather than sleeping and hoping.
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
