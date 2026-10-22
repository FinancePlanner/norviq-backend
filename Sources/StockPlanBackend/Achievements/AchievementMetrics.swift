import Fluent
import FluentSQL
import Foundation
import StockPlanShared
import Vapor

/// What a metric query needs: the database, a logger, the app (for registered
/// repositories) and the evaluation clock. `inTransaction` is true when `db`
/// is a transaction, so a failing metric can be rolled back to a savepoint.
struct AchievementContext: Sendable {
    let db: any Database
    let logger: Logger
    let app: Application
    let now: Date
    var inTransaction = false
}

/// Metric values by key, and the keys whose metric failed (absent from `values`).
struct AchievementMeasurement: Sendable {
    let values: [String: Int]
    let failedKeys: Set<String>
}

/// Turns catalogue keys into numbers for one user. Each value is compared
/// against the key's tier thresholds; yes/no metrics are 0 or 1. Performance
/// metrics are only ever 0 or 1 — no return, value or amount is produced here.
enum AchievementMetrics {
    /// How many of the earliest users are founding members.
    ///
    /// `nonisolated(unsafe)` because it is a test seam: tests lower it while
    /// holding `DatabaseTestLock` and restore it afterwards. Production code
    /// only reads it.
    nonisolated(unsafe) static var foundingLimit = 1000

    /// Instrument key of the benchmark in `market_price_bars` (plain symbol,
    /// as the statistics and dashboard benchmarks use).
    static let benchmarkSymbol = "SPY"

    /// Sector names that don't count towards `craft.diversified`.
    static let unknownSectors: Set<String> = ["Unknown", "Other", ""]

    private static let performanceKeys: Set<String> = ["perf.positive_year", "perf.beat_benchmark", "perf.comeback"]
    private static let checkInKeys: Set<String> = ["discipline.check_in", "discipline.check_in_year"]

    /// Metric value per catalogue key, for definitions in scope. Booleans are 0/1.
    /// Keys it doesn't know are left out; missing data measures 0.
    ///
    /// Each metric is isolated: one that fails is logged and left out, so it
    /// can't block the others' unlocks.
    static func measure(userId: UUID, keys: Set<String>, ctx: AchievementContext) async throws -> [String: Int] {
        try await measurement(userId: userId, keys: keys, ctx: ctx).values
    }

    /// `measure`, plus the keys whose metric failed (logged and left out of
    /// `values`). Evaluation needs them: a backfill with a failed metric must
    /// stay pending, or that key would later unlock as news.
    static func measurement(userId: UUID, keys: Set<String>, ctx: AchievementContext) async throws -> AchievementMeasurement {
        var result: [String: Int] = [:]
        var failed: Set<String> = []
        guard let sql = ctx.db as? any SQLDatabase else { return AchievementMeasurement(values: result, failedKeys: failed) }

        for key in keys.sorted() {
            guard let query = countQuery(for: key, userId: userId, now: ctx.now) else { continue }
            result[key] = await isolated([key], sql: sql, ctx: ctx, failed: &failed) { try await scalar(query, on: sql) }
        }

        let wantedCheckIns = keys.intersection(checkInKeys)
        if !wantedCheckIns.isEmpty, let longest = await isolated(wantedCheckIns, sql: sql, ctx: ctx, failed: &failed, {
            let days = try await XPService.checkInDays(for: [userId], on: ctx.db)[userId] ?? []
            return XPService.longestStreak(days: days)
        }) {
            for key in wantedCheckIns {
                result[key] = longest
            }
        }

        if keys.contains("craft.diversified") {
            result["craft.diversified"] = await isolated(["craft.diversified"], sql: sql, ctx: ctx, failed: &failed) {
                try await knownSectorCount(userId: userId, ctx: ctx)
            }
        }

        if keys.contains("discipline.recap_regular") {
            result["discipline.recap_regular"] = await isolated(["discipline.recap_regular"], sql: sql, ctx: ctx, failed: &failed) {
                try await openedMonthlyRecapStreak(userId: userId, on: sql)
            }
        }

        let wantedPerformance = keys.intersection(performanceKeys)
        if !wantedPerformance.isEmpty, let flags = await isolated(wantedPerformance, sql: sql, ctx: ctx, failed: &failed, {
            try await performance(userId: userId, keys: wantedPerformance, ctx: ctx)
        }) {
            for key in wantedPerformance {
                result[key] = flags.contains(key) ? 1 : 0
            }
        }
        return AchievementMeasurement(values: result, failedKeys: failed)
    }

    /// Runs one metric. A failure is logged (keys and error type only), its
    /// keys added to `failed`, and returns nil. Inside a transaction the metric
    /// runs in a savepoint: in Postgres a failed statement would otherwise
    /// abort the whole evaluation.
    private static func isolated<T>(
        _ keys: Set<String>, sql: any SQLDatabase, ctx: AchievementContext, failed: inout Set<String>,
        _ body: () async throws -> T
    ) async -> T? {
        do {
            if ctx.inTransaction {
                return try await AchievementService.savepoint(sql, name: "achievement_metric", body)
            }
            return try await body()
        } catch {
            ctx.logger.warning(
                "achievements.metric failed key=\(keys.sorted().joined(separator: ",")) error=\(String(reflecting: type(of: error)))"
            )
            failed.formUnion(keys)
            return nil
        }
    }

    // MARK: - SQL metrics

    /// One query per key. Counts are rows; `exists` keys are 0/1.
    private static func countQuery(for key: String, userId: UUID, now: Date) -> SQLQueryString? {
        switch key {
        case "start.first_holding":
            return """
            SELECT (EXISTS (SELECT 1 FROM onboarding_state WHERE user_id = \(bind: userId) AND first_holding_at IS NOT NULL)
                 OR EXISTS (SELECT 1 FROM stocks WHERE user_id = \(bind: userId)))::int AS n
            """
        case "start.first_budget":
            return exists("onboarding_state", userId: userId, where: "first_budget_at IS NOT NULL")
        case "start.first_goal":
            return """
            SELECT (EXISTS (SELECT 1 FROM onboarding_state WHERE user_id = \(bind: userId) AND first_goal_at IS NOT NULL)
                 OR EXISTS (SELECT 1 FROM goals WHERE user_id = \(bind: userId)))::int AS n
            """
        case "start.onboarded":
            return exists("onboarding_state", userId: userId, where: "funnel_completed_at IS NOT NULL")
        case "start.bank_linked":
            return exists("bank_connections", userId: userId)
        case "start.broker_linked":
            return exists("broker_connections", userId: userId)
        case "discipline.budget_streak":
            return "SELECT COALESCE(MAX(best_months), 0)::int AS n FROM gamification_budget_streaks WHERE user_id = \(bind: userId)"
        case "discipline.expense_days":
            return """
            SELECT COUNT(DISTINCT (occurred_on AT TIME ZONE 'UTC')::date)::int AS n
            FROM expenses WHERE user_id = \(bind: userId)
            """
        case "craft.thesis":
            return count("research_notes", userId: userId, where: "btrim(COALESCE(thesis, '')) <> ''")
        case "craft.memo_saved":
            return exists("position_memos", userId: userId, where: "bookmarked = true")
        case "craft.watchlist_review":
            return count("watchlist_items", userId: userId, where: "last_reviewed_at IS NOT NULL")
        case "craft.target_hit":
            return count("targets", userId: userId, where: "alert_triggered_at IS NOT NULL")
        case "craft.position_sizing":
            return exists("terminal_positions", userId: userId)
        case "craft.rebalanced":
            return exists("rebalance_plans", userId: userId, column: "created_by_user_id", where: "completed_at IS NOT NULL")
        case "craft.patient_capital":
            let cutoff = now.addingTimeInterval(-365 * 86400)
            return """
            SELECT EXISTS (SELECT 1 FROM stocks WHERE user_id = \(bind: userId) AND buy_date <= \(bind: cutoff))::int AS n
            """
        case "plan.retirement":
            // Retirement plans belong to a portfolio; archiving the portfolio archives the plan.
            return """
            SELECT EXISTS (
                SELECT 1 FROM retirement_plans rp
                JOIN portfolio_lists pl ON pl.id = rp.portfolio_id
                WHERE pl.user_id = \(bind: userId) AND pl.archived_at IS NULL
            )::int AS n
            """
        case "plan.scenario":
            return count("scenario_runs", userId: userId, where: "completed_at IS NOT NULL")
        case "plan.goal_done":
            return count("goals", userId: userId, where: "completed_at IS NOT NULL")
        case "plan.contributions":
            return count("financial_goal_contributions", userId: userId)
        case "learn.articles":
            // Same key the articles controller writes: Swift's uppercase uuidString.
            return """
            SELECT COUNT(DISTINCT article_id)::int AS n FROM article_views
            WHERE viewer_key = \(bind: "u:\(userId.uuidString)")
            """
        case "learn.muse":
            return count("ai_conversations", userId: userId)
        case "learn.mcp":
            return """
            SELECT (EXISTS (SELECT 1 FROM personal_access_tokens WHERE user_id = \(bind: userId) AND revoked_at IS NULL)
                 OR EXISTS (SELECT 1 FROM oauth_tokens WHERE user_id = \(bind: userId) AND revoked_at IS NULL))::int AS n
            """
        case "learn.pilot":
            return exists("pilot_follows", userId: userId)
        case "social.friends":
            return count("social_friendships", userId: userId)
        case "social.first_post":
            return exists("board_posts", userId: userId, column: "author_id", where: "deleted_at IS NULL AND ai_generated = false")
        case "social.popular_post":
            return """
            SELECT GREATEST(COALESCE(MAX(score), 0), 0)::int AS n FROM board_posts
            WHERE author_id = \(bind: userId) AND deleted_at IS NULL AND ai_generated = false
            """
        case "social.group":
            return exists("group_members", userId: userId)
        case "hidden.founding_member":
            // Rank by created_at, ties broken by id; a user without created_at never qualifies.
            return """
            SELECT (u.created_at IS NOT NULL AND (
                SELECT COUNT(*) FROM users o
                WHERE o.created_at < u.created_at OR (o.created_at = u.created_at AND o.id < u.id)
            ) < \(bind: foundingLimit))::int AS n
            FROM users u WHERE u.id = \(bind: userId)
            """
        default:
            return nil
        }
    }

    /// `table`, `column` and `condition` are always literals from `countQuery`, never user input.
    private static func count(_ table: String, userId: UUID, column: String = "user_id", where condition: String = "TRUE") -> SQLQueryString {
        "SELECT COUNT(*)::int AS n FROM \(unsafeRaw: table) WHERE \(unsafeRaw: column) = \(bind: userId) AND (\(unsafeRaw: condition))"
    }

    private static func exists(_ table: String, userId: UUID, column: String = "user_id", where condition: String = "TRUE") -> SQLQueryString {
        "SELECT EXISTS (SELECT 1 FROM \(unsafeRaw: table) WHERE \(unsafeRaw: column) = \(bind: userId) AND (\(unsafeRaw: condition)))::int AS n"
    }

    private static func scalar(_ query: SQLQueryString, on sql: any SQLDatabase) async throws -> Int {
        guard let row = try await sql.raw(query).first() else { return 0 }
        return try row.decode(column: "n", as: Int?.self) ?? 0
    }

    // MARK: - Recaps

    /// Longest run of consecutive calendar months whose monthly recap was opened.
    /// Months are read from `period_key` ("2026-10") through `RecapPeriod.parse`;
    /// a month generated but never opened breaks the run.
    private static func openedMonthlyRecapStreak(userId: UUID, on sql: any SQLDatabase) async throws -> Int {
        let rows = try await sql.raw("""
        SELECT period_key FROM recaps
        WHERE user_id = \(bind: userId) AND period_kind = \(bind: RecapPeriodKind.month.rawValue) AND opened_at IS NOT NULL
        """).all()
        let months = Set(rows.compactMap { row -> Int? in
            guard let key = try? row.decode(column: "period_key", as: String.self),
                  let period = RecapPeriod.parse(kind: RecapPeriodKind.month.rawValue, key: key),
                  let month = period.month
            else { return nil }
            return period.year * 12 + (month - 1)
        })
        return XPService.longestStreak(days: months)
    }

    // MARK: - Diversified

    /// Distinct known sectors in the user's holdings, from the statistics
    /// repository (database only, no network). Sectors with no market value
    /// don't count.
    private static func knownSectorCount(userId: UUID, ctx: AchievementContext) async throws -> Int {
        let options = StatisticsQueryOptions(period: .oneMonth, top: 10, benchmarkSymbol: benchmarkSymbol, asOfDate: ctx.now)
        let model = try await ctx.app.statisticsRepository.sectorAllocation(userId: userId, options: options, on: ctx.db)
        let sectors = model.importedStocks.sectorAllocations
            .filter { $0.value > 0 }
            .map { $0.sector.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !unknownSectors.contains($0) }
        return Set(sectors).count
    }

    // MARK: - Performance

    /// The requested `perf.*` keys that hold, from the user's actual,
    /// unarchived portfolios — the same lists the leaderboard measures.
    private static func performance(userId: UUID, keys: Set<String>, ctx: AchievementContext) async throws -> Set<String> {
        let listIds = try await PortfolioList.query(on: ctx.db)
            .filter(\.$userId == userId)
            .filter(\.$mode == PortfolioMode.actual.rawValue)
            .filter(\.$archivedAt == nil)
            .all()
            .compactMap(\.id)
        guard !listIds.isEmpty else { return [] }

        let snapshots = try await PortfolioValueSnapshot.query(on: ctx.db)
            .filter(\.$userId == userId)
            .filter(\.$portfolioListId ~~ listIds)
            .filter(\.$capturedOn <= ctx.now)
            .all()
        let index = AchievementPerformance.index(LeaderboardReturns.points(from: snapshots, listIds: listIds))
        guard index.count >= 2 else { return [] }

        var held: Set<String> = []
        if keys.contains("perf.positive_year") {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
            if AchievementPerformance.hasPositiveYear(index, calendar: calendar) {
                held.insert("perf.positive_year")
            }
        }
        if keys.contains("perf.beat_benchmark") {
            // Local bars only; with none stored this is simply false.
            let from = PortfolioSnapshotValuator.addDays(ctx.now, days: -375)
            let bars = try await MarketPriceBarRepository()
                .adjustedCloses(instrumentKey: benchmarkSymbol, from: from, to: ctx.now, on: ctx.db)
                .map { (day: $0.date, close: $0.close) }
            if AchievementPerformance.beatBenchmark(index, benchmark: bars, asOf: ctx.now) {
                held.insert("perf.beat_benchmark")
            }
        }
        if keys.contains("perf.comeback"), AchievementPerformance.hasComeback(index) {
            held.insert("perf.comeback")
        }
        return held
    }
}
