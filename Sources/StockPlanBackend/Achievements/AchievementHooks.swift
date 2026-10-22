import Foundation
import NIOConcurrencyHelpers
import Vapor

/// Live achievement checks after a user acts. Hooks only enqueue: the
/// evaluation runs detached, after `delay`, on the application's database and
/// never inside the caller's transaction or request.
///
/// Coalescing, per user:
/// - scheduled while already pending (waiting out `delay`): nothing more —
///   the pending run will see the new state;
/// - scheduled while their evaluation runs: one more run is queued after it
///   finishes, however many schedules arrived meanwhile;
/// - otherwise: a new run starts.
///
/// The bookkeeping lives in a lock rather than in actor isolation so that
/// `schedule` can stay synchronous and record the user before it returns:
/// a `waitUntilIdle` that follows can never miss it.
actor AchievementHooks {
    static let shared = AchievementHooks()

    /// How long a run waits before evaluating, so a burst of writes collapses
    /// into one evaluation. Production 2s.
    ///
    /// `nonisolated(unsafe)` because it is a test seam: tests lower it while
    /// holding `DatabaseTestLock` and restore it afterwards. Production code
    /// only reads it.
    nonisolated(unsafe) static var delay: Duration = .seconds(2)

    private struct State {
        /// Waiting out `delay`; further schedules are absorbed.
        var pending: Set<UUID> = []
        /// Evaluating now.
        var running: Set<UUID> = []
        /// Scheduled while running: run once more afterwards.
        var rerun: Set<UUID> = []
        /// Users with a run pending or in progress.
        var active = 0
        /// Callers of `waitUntilIdle` to resume when `active` reaches 0.
        var idleWaiters: [CheckedContinuation<Void, Never>] = []
        /// Evaluations started since launch; tests compare deltas.
        var evaluationsRun = 0
    }

    private let state = NIOLockedValueBox(State())

    /// No-op when `ACHIEVEMENTS_ENABLED` is off. Coalesces: a user already
    /// pending is not re-queued.
    nonisolated func schedule(_ userId: UUID, app: Application) {
        guard AchievementsConfiguration.fromEnvironment().enabled else { return }
        let start = state.withLockedValue { state -> Bool in
            if state.pending.contains(userId) {
                return false
            }
            if state.running.contains(userId) {
                state.rerun.insert(userId)
                return false
            }
            state.pending.insert(userId)
            state.active += 1
            return true
        }
        if start {
            launch(userId, app: app)
        }
    }

    /// Tests: returns once every queued and running evaluation has finished,
    /// including re-runs.
    func waitUntilIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle = state.withLockedValue { state -> Bool in
                guard state.active > 0 else { return true }
                state.idleWaiters.append(continuation)
                return false
            }
            if idle {
                continuation.resume()
            }
        }
    }

    /// True while this user's evaluation is running (past `delay`).
    nonisolated func isRunning(_ userId: UUID) -> Bool {
        state.withLockedValue { $0.running.contains(userId) }
    }

    /// Evaluations started since launch. Tests compare before and after.
    nonisolated var evaluationsRun: Int {
        state.withLockedValue { $0.evaluationsRun }
    }

    /// One run for a user already marked pending and counted in `active`.
    private nonisolated func launch(_ userId: UUID, app: Application) {
        Task.detached {
            try? await Task.sleep(for: Self.delay)
            self.state.withLockedValue { state in
                state.pending.remove(userId)
                state.running.insert(userId)
                state.evaluationsRun += 1
            }
            let ctx = AchievementContext(db: app.db, logger: app.logger, app: app, now: Date())
            await AchievementService.evaluateBestEffort(userId: userId, ctx: ctx)
            self.finish(userId, app: app)
        }
    }

    private nonisolated func finish(_ userId: UUID, app: Application) {
        let (again, waiters) = state.withLockedValue { state -> (Bool, [CheckedContinuation<Void, Never>]) in
            state.running.remove(userId)
            if state.rerun.remove(userId) != nil {
                // Still counted in `active`: the re-run takes this run's place.
                state.pending.insert(userId)
                return (true, [])
            }
            state.active -= 1
            guard state.active == 0 else { return (false, []) }
            let waiters = state.idleWaiters
            state.idleWaiters = []
            return (false, waiters)
        }
        if again {
            launch(userId, app: app)
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

extension Request {
    /// Queues a live achievement check for each user. Call it after the
    /// write commits; it only enqueues, so a call inside a transaction is
    /// harmless (the evaluation runs `AchievementHooks.delay` later, on its own).
    func scheduleAchievementCheck(for userIds: UUID...) {
        for userId in userIds {
            AchievementHooks.shared.schedule(userId, app: application)
        }
    }
}
