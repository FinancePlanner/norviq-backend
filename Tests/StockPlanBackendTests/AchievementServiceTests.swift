import Fluent
import FluentSQL
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// `AchievementService.evaluate` against a real database: sources, XP,
/// tiers, sweep-only definitions, races and the legacy badge dual-write.
@Suite("Achievement service", .serialized)
struct AchievementServiceTests {
    private func withApp(
        leaderboards: Bool = true, activated: Bool = true, _ test: (Application) async throws -> Void
    ) async throws {
        try await DatabaseTestLock.withLock {
            setenv("SOCIAL_ENABLED", "1", 1)
            setenv("SOCIAL_LEADERBOARDS_ENABLED", leaderboards ? "1" : "0", 1)
            defer {
                unsetenv("SOCIAL_ENABLED")
                unsetenv("SOCIAL_LEADERBOARDS_ENABLED")
            }
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                if activated {
                    // Achievements went live long ago, so a freshly registered user is live.
                    try await AchievementService.ensureActivated(at: Date(timeIntervalSince1970: 0), on: app.db)
                }
                try await test(app)
                try await app.autoRevert()
            } catch {
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func register(_ app: Application, _ id: String) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "achs_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "achs+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var response: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        })
        return try #require(response)
    }

    private func context(_ app: Application, now: Date = Date()) -> AchievementContext {
        AchievementContext(db: app.db, logger: app.logger, app: app, now: now)
    }

    private func addStock(_ app: Application, userId: UUID, symbol: String = "AAPL", boughtDaysAgo: Int = 10) async throws {
        let listId = try await ensureDefaultPortfolioListId(userId: userId, on: app.db)
        try await Stock(
            userId: userId, portfolioListId: listId, symbol: symbol, shares: 1, buyPrice: 100,
            buyDate: Date().addingTimeInterval(-Double(boughtDaysAgo) * 86400)
        ).save(on: app.db)
    }

    /// Marks a user the way a first evaluation marks a user that predates activation.
    private func markForBackfill(_ app: Application, userId: UUID) async throws {
        try await AchievementEvaluation(userId: userId, needsBackfill: true).save(on: app.db)
    }

    private func checkIn(_ app: Application, userId: UUID, days: ClosedRange<Int>) async throws {
        let calendar = GamificationCalendar.calendar(GamificationCalendar.utc)
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        for offset in days {
            let day = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            try await GamificationCheckIn(
                userId: userId, localDate: GamificationCalendar.localDate(day, in: GamificationCalendar.utc), timeZone: "UTC"
            ).save(on: app.db)
        }
    }

    private func achievements(_ app: Application, userId: UUID) async throws -> [UserAchievement] {
        try await UserAchievement.query(on: app.db).filter(\.$user.$id == userId).all()
    }

    private func xpEvents(_ app: Application, userId: UUID) async throws -> [GamificationXPEvent] {
        try await GamificationXPEvent.query(on: app.db).filter(\.$userId == userId).all()
    }

    @Test("Backfill for existing users is silent and excluded from leaderboards")
    func backfillIsSilentAndExcluded() async throws {
        try await withApp { app in
            let user = try await register(app, "backfill")
            try await markForBackfill(app, userId: user.userId)
            try await addStock(app, userId: user.userId)
            let onboarding = try await OnboardingState.query(on: app.db).filter(\.$userId == user.userId).first()
                ?? { let state = OnboardingState(); state.userId = user.userId; return state }()
            onboarding.firstHoldingAt = Date()
            try await onboarding.save(on: app.db)

            let inserted = try await AchievementService.evaluate(userId: user.userId, scope: .live, ctx: context(app))
            #expect(inserted.contains { $0.achievementKey == "start.first_holding" })

            let row = try #require(try await achievements(app, userId: user.userId)
                .first { $0.achievementKey == "start.first_holding" })
            #expect(row.tier == "")
            #expect(row.source == AchievementSource.backfill.rawValue)
            #expect(row.seenAt != nil)

            let xp = try #require(try await xpEvents(app, userId: user.userId)
                .first { $0.dedupeKey == "achievement:start.first_holding:" })
            #expect(xp.type == XPEventTypeDTO.badgeEarned.rawValue)
            #expect(xp.points == 25)
            #expect(xp.excludeFromLeaderboard == true)

            let evaluation = try #require(try await AchievementEvaluation.query(on: app.db)
                .filter(\.$userId == user.userId).first())
            #expect(evaluation.needsBackfill == false)
            #expect(evaluation.lastEvaluatedAt != nil)
            #expect(evaluation.lastSweptAt != nil)
        }
    }

    @Test("A user registered after activation is evaluated live")
    func newUserIsLive() async throws {
        try await withApp { app in
            let user = try await register(app, "live")
            #expect(try await AchievementEvaluation.query(on: app.db).filter(\.$userId == user.userId).count() == 0)
            try await addStock(app, userId: user.userId)

            try await AchievementService.evaluate(userId: user.userId, scope: .live, ctx: context(app))

            let row = try #require(try await achievements(app, userId: user.userId)
                .first { $0.achievementKey == "start.first_holding" })
            #expect(row.source == AchievementSource.live.rawValue)
            #expect(row.seenAt == nil)
            let xp = try #require(try await xpEvents(app, userId: user.userId)
                .first { $0.dedupeKey == "achievement:start.first_holding:" })
            #expect(xp.excludeFromLeaderboard == false)

            let evaluation = try #require(try await AchievementEvaluation.query(on: app.db)
                .filter(\.$userId == user.userId).first())
            #expect(evaluation.needsBackfill == false)
            #expect(evaluation.lastEvaluatedAt != nil)
            #expect(evaluation.lastSweptAt == nil)

            // Evaluating again inserts nothing and pays nothing.
            let again = try await AchievementService.evaluate(userId: user.userId, scope: .live, ctx: context(app))
            #expect(again.isEmpty)
            #expect(try await xpEvents(app, userId: user.userId).count(where: { $0.dedupeKey.hasPrefix("achievement:") })
                == achievements(app, userId: user.userId).count)
        }
    }

    @Test("Concurrent evaluations insert each unlock and pay each XP key once")
    func idempotentUnderRace() async throws {
        for backfill in [false, true] {
            try await withApp { app in
                let user = try await register(app, "race\(backfill)")
                if backfill {
                    try await markForBackfill(app, userId: user.userId)
                }
                try await addStock(app, userId: user.userId, boughtDaysAgo: 400)
                try await checkIn(app, userId: user.userId, days: 0 ... 7)

                async let a = AchievementService.evaluate(userId: user.userId, scope: .live, ctx: context(app))
                async let b = AchievementService.evaluate(userId: user.userId, scope: .sweep, ctx: context(app))
                let (first, second) = try await (a, b)

                let rows = try await achievements(app, userId: user.userId)
                #expect(!rows.isEmpty)
                #expect(first.count + second.count == rows.count)
                let pairs = rows.map { "\($0.achievementKey)|\($0.tier)" }
                #expect(Set(pairs).count == pairs.count)

                let keys = try await xpEvents(app, userId: user.userId).map(\.dedupeKey).filter { $0.hasPrefix("achievement:") }
                #expect(Set(keys).count == keys.count)
                #expect(keys.count == rows.count)

                if backfill {
                    // Whoever ran first did the backfill; nothing may be labelled live.
                    #expect(rows.allSatisfy { $0.source == AchievementSource.backfill.rawValue })
                } else {
                    #expect(!rows.contains { $0.source == AchievementSource.backfill.rawValue })
                }
                #expect(try await AchievementEvaluation.query(on: app.db).filter(\.$userId == user.userId).count() == 1)
            }
        }
    }

    @Test("Tiers unlock one at a time as the metric grows")
    func tiersUnlockIncrementally() async throws {
        try await withApp { app in
            let user = try await register(app, "tiers")
            try await checkIn(app, userId: user.userId, days: 0 ... 6)

            try await AchievementService.evaluate(userId: user.userId, scope: .live, ctx: context(app))
            var streak = try await achievements(app, userId: user.userId).filter { $0.achievementKey == "discipline.check_in" }
            #expect(streak.map(\.tier) == ["bronze"])
            let bronze = try #require(streak.first)
            let bronzeId = try bronze.requireID()
            let bronzeUnlocked = bronze.unlockedAt

            try await checkIn(app, userId: user.userId, days: 7 ... 29)
            let inserted = try await AchievementService.evaluate(userId: user.userId, scope: .live, ctx: context(app))
            #expect(inserted.map { "\($0.achievementKey)|\($0.tier)" }.contains("discipline.check_in|silver"))
            #expect(!inserted.contains { $0.achievementKey == "discipline.check_in" && $0.tier == "bronze" })

            streak = try await achievements(app, userId: user.userId).filter { $0.achievementKey == "discipline.check_in" }
            #expect(Set(streak.map(\.tier)) == ["bronze", "silver"])
            let bronzeAfter = try #require(streak.first { $0.tier == "bronze" })
            #expect(bronzeAfter.id == bronzeId)
            #expect(abs(bronzeAfter.unlockedAt.timeIntervalSince(bronzeUnlocked)) < 0.001)

            let xp = try await xpEvents(app, userId: user.userId)
            #expect(xp.first { $0.dedupeKey == "achievement:discipline.check_in:bronze" }?.points == 25)
            #expect(xp.first { $0.dedupeKey == "achievement:discipline.check_in:silver" }?.points == 50)
        }
    }

    @Test("Sweep-only achievements are skipped by live evaluation")
    func sweepOnlySkippedLive() async throws {
        try await withApp { app in
            let user = try await register(app, "sweep")
            try await addStock(app, userId: user.userId, boughtDaysAgo: 400)

            try await AchievementService.evaluate(userId: user.userId, scope: .live, ctx: context(app))
            #expect(try await !achievements(app, userId: user.userId).contains { $0.achievementKey == "craft.patient_capital" })

            let inserted = try await AchievementService.evaluate(userId: user.userId, scope: .sweep, ctx: context(app))
            #expect(inserted.contains { $0.achievementKey == "craft.patient_capital" })
            let row = try #require(try await achievements(app, userId: user.userId)
                .first { $0.achievementKey == "craft.patient_capital" })
            #expect(row.source == AchievementSource.sweep.rawValue)
            #expect(row.seenAt == nil)

            let evaluation = try #require(try await AchievementEvaluation.query(on: app.db)
                .filter(\.$userId == user.userId).first())
            #expect(evaluation.lastSweptAt != nil)
        }
    }

    @Test("No XP is written while leaderboards are off")
    func noXPWhenLeaderboardsOff() async throws {
        try await withApp(leaderboards: false) { app in
            let user = try await register(app, "noxp")
            try await addStock(app, userId: user.userId)

            try await AchievementService.evaluate(userId: user.userId, scope: .live, ctx: context(app))
            #expect(try await achievements(app, userId: user.userId).contains { $0.achievementKey == "start.first_holding" })
            #expect(try await xpEvents(app, userId: user.userId).isEmpty)
        }
    }

    @Test("Earning a badge also writes its legacy achievement, with no extra XP")
    func legacyDualWrite() async throws {
        try await withApp { app in
            let user = try await register(app, "legacy")
            try await addStock(app, userId: user.userId)

            try await app.testing().test(.GET, "v1/badges", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: user.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let badges = try await UserBadge.query(on: app.db).filter(\.$userId == user.userId).all()
            #expect(badges.contains { $0.badgeType == .firstPurchase && $0.tier == .bronze })

            let rows = try await achievements(app, userId: user.userId)
            #expect(rows.count == badges.count)
            for badge in badges {
                let row = try #require(rows.first {
                    $0.achievementKey == "legacy.\(badge.badgeType.rawValue)" && $0.tier == badge.tier.rawValue
                })
                #expect(row.source == AchievementSource.legacyBadge.rawValue)
                let seen = try #require(row.seenAt)
                #expect(abs(seen.timeIntervalSince(badge.earnedAt)) < 1)
            }

            let xp = try await xpEvents(app, userId: user.userId)
            #expect(xp.count == badges.count)
            #expect(xp.allSatisfy { $0.dedupeKey.hasPrefix("badge_earned:") })
        }
    }

    @Test("Best-effort evaluation does nothing while the flag is off")
    func bestEffortNoOpWhenOff() async throws {
        try await withApp { app in
            unsetenv("ACHIEVEMENTS_ENABLED")
            let user = try await register(app, "off")
            try await addStock(app, userId: user.userId)
            await AchievementService.evaluateBestEffort(userId: user.userId, ctx: context(app))
            #expect(try await achievements(app, userId: user.userId).isEmpty)

            setenv("ACHIEVEMENTS_ENABLED", "1", 1)
            defer { unsetenv("ACHIEVEMENTS_ENABLED") }
            await AchievementService.evaluateBestEffort(userId: user.userId, ctx: context(app))
            #expect(try await achievements(app, userId: user.userId).contains { $0.achievementKey == "start.first_holding" })
        }
    }

    // MARK: - Activation-keyed backfill

    private func activatedAt(_ app: Application) async throws -> Date? {
        let sql = try #require(app.db as? any SQLDatabase)
        return try await sql.raw("SELECT value_at FROM achievement_settings WHERE key = 'activated_at'")
            .first()?.decode(column: "value_at", as: Date.self)
    }

    @Test("A user created before activation is backfilled on first evaluation")
    func userBeforeActivationIsBackfilled() async throws {
        try await withApp(activated: false) { app in
            let user = try await register(app, "preact")
            try await addStock(app, userId: user.userId)
            #expect(try await AchievementEvaluation.query(on: app.db).filter(\.$userId == user.userId).count() == 0)

            // The first evaluation is the activation; this user predates it.
            try await AchievementService.evaluate(userId: user.userId, scope: .live, ctx: context(app, now: Date().addingTimeInterval(1)))

            let row = try #require(try await achievements(app, userId: user.userId)
                .first { $0.achievementKey == "start.first_holding" })
            #expect(row.source == AchievementSource.backfill.rawValue)
            #expect(row.seenAt != nil)
            let xp = try #require(try await xpEvents(app, userId: user.userId)
                .first { $0.dedupeKey == "achievement:start.first_holding:" })
            #expect(xp.excludeFromLeaderboard == true)
            #expect(try await activatedAt(app) != nil)
        }
    }

    @Test("A user created after activation is evaluated live")
    func userAfterActivationIsLive() async throws {
        try await withApp(activated: false) { app in
            let early = try await register(app, "act_first")
            try await AchievementService.evaluate(userId: early.userId, scope: .live, ctx: context(app))
            let activation = try #require(try await activatedAt(app))

            let user = try await register(app, "act_after")
            try await addStock(app, userId: user.userId)
            try await AchievementService.evaluate(userId: user.userId, scope: .live, ctx: context(app))

            let row = try #require(try await achievements(app, userId: user.userId)
                .first { $0.achievementKey == "start.first_holding" })
            #expect(row.source == AchievementSource.live.rawValue)
            #expect(row.seenAt == nil)
            #expect(try await activatedAt(app) == activation)
        }
    }

    @Test("Activation is written once")
    func activationWrittenOnce() async throws {
        try await withApp(activated: false) { app in
            let user = try await register(app, "act_once")
            let first = Date(timeIntervalSince1970: 1_800_000_000)
            try await AchievementService.evaluate(userId: user.userId, scope: .live, ctx: context(app, now: first))
            try await AchievementService.evaluate(userId: user.userId, scope: .sweep, ctx: context(app, now: first.addingTimeInterval(86400)))
            let stored = try #require(try await activatedAt(app))
            #expect(abs(stored.timeIntervalSince(first)) < 1)
        }
    }

    // MARK: - Metric isolation

    @Test("One failing metric does not block other unlocks")
    func failingMetricIsIsolated() async throws {
        try await withApp { app in
            let user = try await register(app, "metricfail")
            try await addStock(app, userId: user.userId)
            let sql = try #require(app.db as? any SQLDatabase)
            // learn.articles reads article_views; make that query fail.
            try await sql.raw("ALTER TABLE article_views RENAME TO article_views_hidden").run()
            let result: Result<[UserAchievement], any Error>
            do {
                result = try await .success(AchievementService.evaluate(userId: user.userId, scope: .sweep, ctx: context(app)))
            } catch {
                result = .failure(error)
            }
            try await sql.raw("ALTER TABLE article_views_hidden RENAME TO article_views").run()

            let inserted = try result.get()
            #expect(inserted.contains { $0.achievementKey == "start.first_holding" })
            let evaluation = try #require(try await AchievementEvaluation.query(on: app.db)
                .filter(\.$userId == user.userId).first())
            #expect(evaluation.lastSweptAt != nil)
        }
    }

    @Test("A metric failure during backfill leaves the backfill pending until it succeeds")
    func failedMetricKeepsBackfillPending() async throws {
        try await withApp(activated: false) { app in
            let user = try await register(app, "bfretry")
            try await addStock(app, userId: user.userId)
            // start.first_goal measures 1 from onboarding state, once its query
            // (which also reads `goals`) can run.
            let onboarding = try await OnboardingState.query(on: app.db).filter(\.$userId == user.userId).first()
                ?? { let state = OnboardingState(); state.userId = user.userId; return state }()
            onboarding.firstGoalAt = Date()
            try await onboarding.save(on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            let now = Date().addingTimeInterval(1)

            // The user predates activation (first evaluation), so this is a backfill.
            // Break every metric that reads `goals`, start.first_goal among them.
            try await sql.raw("ALTER TABLE goals RENAME TO goals_hidden").run()
            let firstRun: Result<[UserAchievement], any Error>
            do {
                firstRun = try await .success(AchievementService.evaluate(
                    userId: user.userId, scope: .live, ctx: context(app, now: now)
                ))
            } catch {
                firstRun = .failure(error)
            }
            try await sql.raw("ALTER TABLE goals_hidden RENAME TO goals").run()

            let first = try firstRun.get()
            #expect(first.contains { $0.achievementKey == "start.first_holding" })
            #expect(!first.contains { $0.achievementKey == "start.first_goal" })
            #expect(first.allSatisfy { $0.source == AchievementSource.backfill.rawValue && $0.seenAt != nil })
            let pending = try #require(try await AchievementEvaluation.query(on: app.db)
                .filter(\.$userId == user.userId).first())
            #expect(pending.needsBackfill == true)
            #expect(pending.lastSweptAt == nil)

            // Table back: the retry is still a backfill and finishes it.
            let second = try await AchievementService.evaluate(
                userId: user.userId, scope: .live, ctx: context(app, now: now.addingTimeInterval(60))
            )
            #expect(!second.contains { $0.achievementKey == "start.first_holding" })
            let goal = try #require(second.first { $0.achievementKey == "start.first_goal" })
            #expect(goal.source == AchievementSource.backfill.rawValue)
            #expect(goal.seenAt != nil)
            let xp = try #require(try await xpEvents(app, userId: user.userId)
                .first { $0.dedupeKey == "achievement:start.first_goal:" })
            #expect(xp.excludeFromLeaderboard == true)
            let done = try #require(try await AchievementEvaluation.query(on: app.db)
                .filter(\.$userId == user.userId).first())
            #expect(done.needsBackfill == false)
            #expect(done.lastSweptAt != nil)
        }
    }
}
