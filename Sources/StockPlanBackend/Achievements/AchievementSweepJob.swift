import Fluent
import FluentSQL
import Foundation
import NIOCore
import Vapor

/// Hourly safety net for achievements: re-evaluates users whose last sweep is
/// more than a day old (or who never had one) with `.sweep` scope, which also
/// covers the sweep-only definitions that live hooks never touch. Leader-locked
/// so only one replica sweeps; a no-op while `ACHIEVEMENTS_ENABLED` is off.
final class AchievementSweepJob: LifecycleHandler, @unchecked Sendable {
    private static let lockName = "achievement_sweep"
    /// A user is due once their last sweep is older than this.
    static let staleAfter: TimeInterval = 24 * 3600

    private let intervalSeconds: Int64
    private let batchSize: Int
    private let state = BackgroundJobState()

    init(intervalSeconds: Int64 = 3600, batchSize: Int = 200) {
        self.intervalSeconds = max(intervalSeconds, 60)
        self.batchSize = max(batchSize, 1)
    }

    func didBoot(_ app: Application) throws {
        let eventLoop = app.eventLoopGroup.next()
        let scheduled = eventLoop.scheduleRepeatedTask(
            initialDelay: .seconds(60),
            delay: .seconds(intervalSeconds)
        ) { _ in
            guard self.state.begin() else {
                app.logger.debug("achievement_sweep skipped overlapping tick")
                return
            }
            let task = Task {
                defer { self.state.finish() }
                await self.runOnce(app)
            }
            self.state.track(task: task)
        }
        state.set(scheduled: scheduled)
    }

    func shutdown(_: Application) {
        state.stopAcceptingRuns()
    }

    func shutdownAsync(_: Application) async {
        await state.stopAndDrain()
    }

    /// One sweep tick. `now` is injectable for tests.
    func runOnce(_ app: Application, now: Date = Date()) async {
        guard AchievementsConfiguration.fromEnvironment().enabled else { return }
        let batchSize = batchSize
        await JobLock.runAsLeader(app, name: Self.lockName) {
            do {
                try await AchievementService.ensureActivated(at: now, on: app.db)
            } catch {
                app.logger.warning("achievement_sweep activation failed error=\(String(reflecting: type(of: error)))")
                return
            }
            await Self.sweep(app, now: now, batchSize: batchSize)
        }
    }

    private static func sweep(_ app: Application, now: Date, batchSize: Int) async {
        let userIds: [UUID]
        do {
            userIds = try await dueUsers(app, now: now, limit: batchSize)
        } catch {
            app.logger.warning("achievement_sweep select failed error=\(String(reflecting: type(of: error)))")
            return
        }
        guard !userIds.isEmpty else { return }

        // One user at a time, outside any transaction: evaluate opens its own
        // transaction and row lock.
        let ctx = AchievementContext(db: app.db, logger: app.logger, app: app, now: now)
        var failed = 0
        for userId in userIds {
            do {
                try await AchievementService.evaluate(userId: userId, scope: .sweep, ctx: ctx)
            } catch {
                failed += 1
                app.logger.warning(
                    "achievement_sweep user failed user=\(userId) error=\(String(reflecting: type(of: error)))"
                )
                await stampSwept(userId: userId, now: now, app: app)
            }
        }
        app.logger.info("achievement_sweep ok users=\(userIds.count) failed=\(failed)")
    }

    /// Users with no evaluation row, a null `last_swept_at`, or one older than
    /// 24h; never-swept first, then by user id.
    private static func dueUsers(_ app: Application, now: Date, limit: Int) async throws -> [UUID] {
        guard let sql = app.db as? any SQLDatabase else { return [] }
        let cutoff = now.addingTimeInterval(-staleAfter)
        let rows = try await sql.raw("""
        SELECT u.id AS id
        FROM users u
        LEFT JOIN achievement_evaluations e ON e.user_id = u.id
        WHERE e.id IS NULL OR e.last_swept_at IS NULL OR e.last_swept_at < \(bind: cutoff)
        ORDER BY e.last_swept_at ASC NULLS FIRST, u.id
        LIMIT \(bind: limit)
        """).all()
        return try rows.map { try $0.decode(column: "id", as: UUID.self) }
    }

    /// evaluate stamps `last_swept_at` only on success. After a failure, stamp
    /// it here so one permanently broken user is retried daily rather than on
    /// every tick. A row created here follows the same backfill rule as a first
    /// evaluation. Best effort: a failure to stamp is logged and ignored.
    static func stampSwept(userId: UUID, now: Date, app: Application) async {
        guard let sql = app.db as? any SQLDatabase else { return }
        do {
            try await sql.raw("""
            INSERT INTO achievement_evaluations (id, user_id, needs_backfill, last_swept_at)
            SELECT \(bind: UUID()), u.id, \(unsafeRaw: AchievementService.backfillRule), \(bind: now)
            FROM users u \(unsafeRaw: AchievementService.activationJoin)
            WHERE u.id = \(bind: userId)
            ON CONFLICT (user_id) DO UPDATE SET last_swept_at = EXCLUDED.last_swept_at
            """).run()
        } catch {
            app.logger.warning(
                "achievement_sweep stamp failed user=\(userId) error=\(String(reflecting: type(of: error)))"
            )
        }
    }
}
