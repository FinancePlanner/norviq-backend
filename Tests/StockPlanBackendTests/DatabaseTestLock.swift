import Foundation
import Testing
import Vapor

/// Bounded readers–writer gate behind ``DatabaseTestLock``.
///
/// The thing being guarded is the **process environment**, not the database.
/// Every test schema is already private to one `Application` (see
/// `ConfigureBootstrap.swift`, `stockplan_test_<uuid>`), so two database tests
/// never touch each other's rows. What they do share is `environ`: booting an
/// app reads it through `Environment.get`, and a handful of tests write it with
/// `setenv`/`unsetenv`. glibc's `getenv` is not safe against a concurrent
/// `setenv` — that is the SIGSEGV of 4a0b137 and 741c55a.
///
/// Readers and writers, not one mutex:
///   * **shared** — a test that only *reads* the environment (boots an app,
///     migrates, queries its own schema). Many may run at once.
///   * **exclusive** — a test that *writes* the environment. Runs alone.
///
/// `maxConcurrentReaders` is deliberately small. Each booted app opens a
/// Postgres connection per event loop it touches; the dev server ships
/// `max_connections = 100` and a full run was measured at ~10 live connections
/// per app, so four in flight leaves generous headroom. Raising it trades
/// wall-clock for `FATAL: sorry, too many clients already`.
actor DatabaseAccessGate {
    static let maxConcurrentReaders = 4

    private var readers = 0
    private var writer = false
    private var readerWaiters: [CheckedContinuation<Void, Never>] = []
    private var writerWaiters: [CheckedContinuation<Void, Never>] = []
    private var warmUp: Task<String?, Never>?
    private var reportedWarmUpFailure = false

    /// Loads the dotenv files once, with nothing else running.
    ///
    /// `Application.make` ends in `DotEnvFile.load`, which `setenv`s every
    /// `KEY=VALUE` of `.env.<environment>` and `.env`. That is a *write*, so
    /// the first app boot of the process is exactly the hazard this gate
    /// exists to prevent — and under the old global mutex it was accidentally
    /// safe because every boot was serialised. Every acquirer awaits this
    /// first, so the writes land before any test body runs.
    ///
    /// This only establishes the *cold* state. Keeping it that way is
    /// ``DatabaseTestLock/withLock``'s job: it restores the environment an
    /// exclusive scope was handed, so a test cannot remove a key that `.env`
    /// defines and leave the next boot with a real `setenv` to perform.
    ///
    /// A failed warm-up is not swallowed. If it were, every later boot would
    /// perform the genuine first dotenv write under reader concurrency, which
    /// is precisely the crash this exists to prevent, and nothing would say so.
    private func warmDotEnv() async {
        if warmUp == nil {
            warmUp = Task.detached {
                do {
                    let app = try await Application.make(.testing)
                    try await app.asyncShutdown()
                    return nil
                } catch {
                    return String(describing: error)
                }
            }
        }

        guard let task = warmUp else { return }
        guard let failure = await task.value else { return }
        guard !reportedWarmUpFailure else { return }
        reportedWarmUpFailure = true
        // Reached from the test's own task, so this is attributed to whichever
        // test happened to be first through the gate.
        Issue.record(
            """
            Dotenv warm-up failed, so the first Application.make of this process \
            will perform the real setenv storm under reader concurrency. Treat \
            any SIGSEGV in Environment.get after this as caused by it. Error: \
            \(failure)
            """
        )
    }

    func acquireShared() async {
        await warmDotEnv()
        guard writer || !writerWaiters.isEmpty || readers >= Self.maxConcurrentReaders else {
            readers += 1
            return
        }
        // Baton passing: `wake()` takes the slot on the waiter's behalf before
        // resuming it, so a resumed waiter never has to re-check and cannot
        // lose a wakeup to a barger.
        await withCheckedContinuation { readerWaiters.append($0) }
    }

    func releaseShared() {
        readers -= 1
        wake()
    }

    func acquireExclusive() async {
        await warmDotEnv()
        guard writer || readers > 0 || !writerWaiters.isEmpty else {
            writer = true
            return
        }
        await withCheckedContinuation { writerWaiters.append($0) }
    }

    func releaseExclusive() {
        writer = false
        wake()
    }

    /// Writer-preferred: a queued writer goes next, so a steady stream of
    /// readers cannot starve the env-mutating tests.
    private func wake() {
        guard !writer else { return }
        if readers == 0, !writerWaiters.isEmpty {
            writer = true
            writerWaiters.removeFirst().resume()
            return
        }
        guard writerWaiters.isEmpty else { return }
        while readers < Self.maxConcurrentReaders, !readerWaiters.isEmpty {
            readers += 1
            readerWaiters.removeFirst().resume()
        }
    }
}

enum DatabaseTestLock {
    private static let gate = DatabaseAccessGate()

    private enum Held: Sendable {
        case shared
        case exclusive
    }

    /// Re-entrancy: a suite scoped by `DatabaseLockedTrait` may contain tests
    /// that take the lock themselves; the task-local makes the inner call a
    /// no-op instead of a deadlock.
    @TaskLocal private static var held: Held?

    /// Exclusive access — nothing else in the process runs alongside.
    ///
    /// This is the safe default and the semantics every pre-existing call site
    /// was written against, so it keeps the original name. Use it for anything
    /// that calls `setenv`/`unsetenv`, directly or from a shared helper.
    static func withLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        if let held {
            if held == .shared {
                // Running an environment writer inside a shared scope is the
                // exact race this file exists to prevent. Recording an issue
                // and continuing fails open: the `setenv` still fires next to
                // three readers sitting in `Environment.get`, and the process
                // can be gone before anyone reads the diagnostic. Stop here —
                // a hard, legible halt beats a segfault in an unrelated suite.
                preconditionFailure(
                    """
                    withLock (exclusive) was entered from inside withSharedAccess. \
                    The enclosing suite mutates the process environment and must not \
                    be marked shared — drop its withSharedAccess back to withLock.
                    """
                )
            }
            return try await operation()
        }
        await gate.acquireExclusive()
        let entryEnvironment = ProcessInfo.processInfo.environment
        do {
            let result = try await $held.withValue(.exclusive) { try await operation() }
            restore(entryEnvironment)
            await gate.releaseExclusive()
            return result
        } catch {
            restore(entryEnvironment)
            await gate.releaseExclusive()
            throw error
        }
    }

    /// Puts `environ` back the way the exclusive scope was handed it, while
    /// exclusivity still holds.
    ///
    /// Restoring what a test *added* is the obvious half. The half that matters
    /// is restoring what it *removed*: the usual cleanup idiom here is
    /// `setenv(k, v, 1); defer { unsetenv(k) }`, and three tests apply it to
    /// `BYPASS_BILLING`, which `.env` defines. Leaving the key absent is not
    /// inert — the next `Application.make` reaches `setenv(k, v, 0)` on a
    /// missing name, which is a genuine `environ` mutation (a realloc on
    /// glibc), not the no-op an already-present key gives. Under the old single
    /// mutex no two boots overlapped so it could not bite; with app boots on
    /// the reader side it would fire next to three concurrent `Environment.get`
    /// calls. `warmDotEnv` only establishes the cold state; this keeps it.
    private static func restore(_ snapshot: [String: String]) {
        let current = ProcessInfo.processInfo.environment
        for (key, value) in current where snapshot[key] != value {
            if let original = snapshot[key] {
                setenv(key, original, 1)
            } else {
                unsetenv(key)
            }
        }
        for (key, value) in snapshot where current[key] == nil {
            setenv(key, value, 1)
        }
    }

    /// Shared access — up to ``DatabaseAccessGate/maxConcurrentReaders`` of
    /// these run at once, but never alongside a ``withLock`` holder.
    ///
    /// Only for suites that **read** the environment: boot an app, migrate,
    /// exercise their own private schema. A single `setenv` anywhere reachable
    /// from the scope disqualifies the whole suite, because the helper is
    /// shared by every test in the file.
    static func withSharedAccess<T>(_ operation: () async throws -> T) async rethrows -> T {
        if held != nil {
            return try await operation()
        }
        await gate.acquireShared()
        do {
            let result = try await $held.withValue(.shared) { try await operation() }
            await gate.releaseShared()
            return result
        } catch {
            await gate.releaseShared()
            throw error
        }
    }
}

/// Runs every test of a suite exclusively, under ``DatabaseTestLock/withLock``.
///
/// Suites that mutate the process environment (`setenv`/`unsetenv`) must not
/// overlap the app-booting suites, which read it through `Environment.get`:
/// glibc's `getenv` is not safe against a concurrent `setenv`, and CI on
/// Linux crashed with SIGSEGV in `AIModelRouterTests` (2026-09-03) exactly
/// that way. Carry this trait on anything that writes the environment; the
/// app-booting suites take the reader side of the same gate, so the two groups
/// are excluded from each other without being serialised among themselves.
struct DatabaseLockedTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool {
        true
    }

    func provideScope(
        for _: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        // Scope is offered at suite, function, and case level; the gate is
        // not re-entrant on its own, so lock once, at the innermost (case)
        // level.
        guard testCase != nil else {
            try await function()
            return
        }
        try await DatabaseTestLock.withLock {
            try await function()
        }
    }
}

extension Trait where Self == DatabaseLockedTrait {
    static var databaseLocked: Self {
        DatabaseLockedTrait()
    }
}
