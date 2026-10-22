import Fluent
import FluentSQL
import Foundation
import StockPlanShared
import Vapor

/// Which definitions an evaluation looks at. `live` skips `sweepOnly`
/// definitions; `sweep` (the nightly job, and every backfill) covers them all.
enum AchievementScope: Sendable {
    case live, sweep
}

/// Turns metrics into unlocks. Idempotent: each (key, tier) is inserted once
/// and its XP paid once.
///
/// Evaluations of one user are serialized by a `SELECT … FOR UPDATE` on the
/// user's `achievement_evaluations` row, held for the whole evaluation. So
/// `needsBackfill` is read and cleared under the lock: a caller racing the
/// first evaluation of an existing user waits, then finds the backfill done
/// and the unlocks already present, and can never relabel them `live`.
///
/// Backfill is keyed to activation, not to the migration: the first time
/// achievements run with the flag on (first sweep tick or first evaluation)
/// stores `activated_at`, and a user without an evaluation row is backfilled
/// exactly when they were created before it (`backfillRule`).
enum AchievementService {
    /// `achievement_settings` key of the activation timestamp.
    static let activationKey = "activated_at"

    /// SQL boolean: should the user `u` (joined with the activation row as
    /// `a`) start with a backfill? True when achievements are active and the
    /// user predates activation; a user with no `created_at` predates it.
    static let backfillRule = "(a.value_at IS NOT NULL AND (u.created_at IS NULL OR u.created_at < a.value_at))"

    /// Joins the activation row as `a`; pair with `backfillRule`.
    static let activationJoin = "LEFT JOIN achievement_settings a ON a.key = 'activated_at'"

    /// Records that achievements are running, at `now`, the first time it is
    /// called; later calls keep the first value. Callers are only reached with
    /// the flag on (the sweep, the gated routes and `evaluateBestEffort`).
    static func ensureActivated(at now: Date, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        try await sql.raw("""
        INSERT INTO achievement_settings (key, value_at) VALUES (\(bind: activationKey), \(bind: now))
        ON CONFLICT (key) DO NOTHING
        """).run()
    }

    /// Returns newly inserted unlocks. Idempotent. Never pays XP twice.
    ///
    /// Must be called outside any caller transaction: it opens its own
    /// transaction and holds the user's row lock for the whole evaluation, and
    /// relies on savepoints of that transaction to survive failed statements.
    @discardableResult
    static func evaluate(userId: UUID, scope: AchievementScope, ctx: AchievementContext) async throws -> [UserAchievement] {
        guard ctx.db is any SQLDatabase else { return [] }
        try await ensureActivated(at: ctx.now, on: ctx.db)
        try await ensureEvaluationRow(userId: userId, on: ctx.db)

        return try await ctx.db.transaction { tx in
            guard let sql = tx as? any SQLDatabase else { return [] }
            let locked = try await sql.raw("""
            SELECT needs_backfill FROM achievement_evaluations WHERE user_id = \(bind: userId) FOR UPDATE
            """).first()
            guard let locked else { return [] }
            let needsBackfill = try locked.decode(column: "needs_backfill", as: Bool.self)

            let effectiveScope: AchievementScope = needsBackfill ? .sweep : scope
            let source: AchievementSource = needsBackfill ? .backfill : (scope == .sweep ? .sweep : .live)
            let definitions = AchievementCatalogue.all.filter { effectiveScope == .sweep || !$0.sweepOnly }

            let txCtx = AchievementContext(db: tx, logger: ctx.logger, app: ctx.app, now: ctx.now, inTransaction: true)
            let metrics = try await AchievementMetrics.measure(
                userId: userId, keys: Set(definitions.map(\.key)), ctx: txCtx
            )
            let held = try await UserAchievement.query(on: tx)
                .filter(\.$user.$id == userId)
                .all()
                .map { UnlockKey(key: $0.achievementKey, tier: $0.tier) }
            let existing = Set(held)
            let payXP = SocialConfiguration.fromEnvironment().leaderboards

            var inserted: [UserAchievement] = []
            for definition in definitions {
                guard let value = metrics[definition.key] else { continue }
                for spec in definition.tiers where value >= spec.threshold {
                    guard !existing.contains(UnlockKey(key: definition.key, tier: spec.tier)) else { continue }
                    let unlock = UserAchievement(
                        userId: userId, achievementKey: definition.key, tier: spec.tier,
                        unlockedAt: ctx.now, source: source
                    )
                    if needsBackfill {
                        // Backfilled unlocks are history, not news: never celebrated.
                        unlock.seenAt = ctx.now
                    }
                    guard try await insertIgnoringDuplicate(unlock, on: tx, sql: sql) else { continue }
                    inserted.append(unlock)
                    if payXP {
                        await award(
                            spec: spec, key: definition.key, userId: userId,
                            excludeFromLeaderboard: needsBackfill, on: tx, sql: sql, logger: ctx.logger
                        )
                    }
                }
            }

            var update = AchievementEvaluation.query(on: tx)
                .filter(\.$userId == userId)
                .set(\.$needsBackfill, to: false)
                .set(\.$lastEvaluatedAt, to: ctx.now)
            if effectiveScope == .sweep {
                update = update.set(\.$lastSweptAt, to: ctx.now)
            }
            try await update.update()
            return inserted
        }
    }

    /// Hooks call this (PR B). Swallows errors; no-op when flag off.
    ///
    /// Like `evaluate`, must be called outside any caller transaction — after
    /// the caller's own write has committed, never inside it.
    static func evaluateBestEffort(userId: UUID, ctx: AchievementContext) async {
        guard AchievementsConfiguration.fromEnvironment().enabled else { return }
        do {
            try await evaluate(userId: userId, scope: .live, ctx: ctx)
        } catch {
            ctx.logger.warning("achievements.evaluate failed error=\(String(reflecting: type(of: error)))")
        }
    }

    /// Mirrors a newly earned legacy badge as `legacy.<raw>` so the achievements
    /// view matches `user_badges`. Already seen (the badge flow showed it) and
    /// no XP (the badge flow paid it). Written whatever the flag, so turning
    /// achievements on later finds every badge. Never throws.
    static func recordLegacyBadge(userId: UUID, badge: BadgeType, tier: BadgeTier, earnedAt: Date, on db: any Database) async {
        guard let sql = db as? any SQLDatabase else { return }
        do {
            // ON CONFLICT rather than catching the error, so a caller's
            // transaction is never left aborted.
            try await sql.raw("""
            INSERT INTO user_achievements (id, user_id, achievement_key, tier, unlocked_at, source, seen_at, created_at)
            VALUES (\(bind: UUID()), \(bind: userId), \(bind: "legacy.\(badge.rawValue)"), \(bind: tier.rawValue),
                    \(bind: earnedAt), \(bind: AchievementSource.legacyBadge.rawValue), \(bind: earnedAt), now())
            ON CONFLICT DO NOTHING
            """).run()
        } catch {
            db.logger.warning("achievements.legacy_badge failed error=\(String(reflecting: type(of: error)))")
        }
    }

    // MARK: - Helpers

    private struct UnlockKey: Hashable {
        let key: String
        let tier: String
    }

    /// A user's first evaluation creates their row, backfilled exactly when
    /// they predate activation (`backfillRule`). A concurrent first evaluation
    /// may insert it first, which is fine.
    private static func ensureEvaluationRow(userId: UUID, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        try await sql.raw("""
        INSERT INTO achievement_evaluations (id, user_id, needs_backfill)
        SELECT \(bind: UUID()), u.id, \(unsafeRaw: backfillRule)
        FROM users u \(unsafeRaw: activationJoin)
        WHERE u.id = \(bind: userId)
        ON CONFLICT (user_id) DO NOTHING
        """).run()
    }

    /// `XPService.insertIgnoringDuplicate` inside a savepoint: in Postgres a
    /// failed statement aborts the whole transaction, so the savepoint is what
    /// lets a duplicate be ignored and the evaluation carry on.
    private static func insertIgnoringDuplicate(_ unlock: UserAchievement, on tx: any Database, sql: any SQLDatabase) async throws -> Bool {
        do {
            try await savepoint(sql) { try await unlock.create(on: tx) }
            return true
        } catch {
            guard XPService.isConstraintFailure(error) else { throw error }
            return false
        }
    }

    /// Pays the unlock's XP. A failure is logged and rolled back to the
    /// savepoint, so it never costs the unlock itself.
    private static func award(
        spec: AchievementTierSpec, key: String, userId: UUID, excludeFromLeaderboard: Bool,
        on tx: any Database, sql: any SQLDatabase, logger: Logger
    ) async {
        do {
            try await savepoint(sql) {
                try await XPService.award(
                    .badgeEarned, points: spec.xp, to: userId, dedupeKey: "achievement:\(key):\(spec.tier)",
                    excludeFromLeaderboard: excludeFromLeaderboard, on: tx
                )
            }
        } catch {
            logger.warning("achievements.xp failed key=\(key) tier=\(spec.tier) error=\(String(reflecting: type(of: error)))")
        }
    }

    /// Runs `body` so that any error (including one that aborted the
    /// statement) is rolled back to a savepoint and rethrown, leaving the
    /// surrounding transaction usable. Only valid inside a transaction.
    @discardableResult
    static func savepoint<T>(
        _ sql: any SQLDatabase, name: String = "achievement_step", _ body: () async throws -> T
    ) async throws -> T {
        try await sql.raw("SAVEPOINT \(unsafeRaw: name)").run()
        do {
            let value = try await body()
            try await sql.raw("RELEASE SAVEPOINT \(unsafeRaw: name)").run()
            return value
        } catch {
            try await sql.raw("ROLLBACK TO SAVEPOINT \(unsafeRaw: name)").run()
            throw error
        }
    }
}
