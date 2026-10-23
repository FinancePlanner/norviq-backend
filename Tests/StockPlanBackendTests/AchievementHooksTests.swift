import Fluent
import FluentSQL
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// `AchievementHooks`: the flag gate, coalescing of bursts, and the single
/// re-run for a user scheduled while their evaluation is running.
@Suite("Achievement hooks", .serialized)
struct AchievementHooksTests {
    private func withApp(achievements: Bool = true, _ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            if achievements {
                setenv("ACHIEVEMENTS_ENABLED", "1", 1)
            } else {
                unsetenv("ACHIEVEMENTS_ENABLED")
            }
            let previousDelay = AchievementHooks.delay
            AchievementHooks.delay = .milliseconds(50)
            defer {
                AchievementHooks.delay = previousDelay
                unsetenv("ACHIEVEMENTS_ENABLED")
            }
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
                // Achievements went live long ago, so a freshly registered user is live.
                try await AchievementService.ensureActivated(at: Date(timeIntervalSince1970: 0), on: app.db)
                try await test(app)
                // Nothing scheduled may outlive the app it captured.
                await AchievementHooks.shared.waitUntilIdle()
                try await app.autoRevert()
            } catch {
                await AchievementHooks.shared.waitUntilIdle()
                try? await app.autoRevert()
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func register(_ app: Application, _ id: String) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "achh_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "achh+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
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

    private func addStock(_ app: Application, userId: UUID) async throws {
        let listId = try await ensureDefaultPortfolioListId(userId: userId, on: app.db)
        try await Stock(
            userId: userId, portfolioListId: listId, symbol: "AAPL", shares: 1, buyPrice: 100,
            buyDate: Date().addingTimeInterval(-10 * 86400)
        ).save(on: app.db)
    }

    private func evaluation(_ app: Application, userId: UUID) async throws -> AchievementEvaluation? {
        try await AchievementEvaluation.query(on: app.db).filter(\.$userId == userId).first()
    }

    @Test("With the flag off, scheduling evaluates nothing")
    func flagOffSchedulesNothing() async throws {
        try await withApp(achievements: false) { app in
            let user = try await register(app, "off")
            try await addStock(app, userId: user.userId)
            let before = AchievementHooks.shared.evaluationsRun

            AchievementHooks.shared.schedule(user.userId, app: app)
            await AchievementHooks.shared.waitUntilIdle()

            #expect(AchievementHooks.shared.evaluationsRun == before)
            #expect(try await evaluation(app, userId: user.userId) == nil)
            let unlocks = try await UserAchievement.query(on: app.db).filter(\.$user.$id == user.userId).count()
            #expect(unlocks == 0)
        }
    }

    @Test("A burst of schedules for one user runs one evaluation")
    func burstCoalesces() async throws {
        try await withApp { app in
            let user = try await register(app, "burst")
            try await addStock(app, userId: user.userId)
            let before = AchievementHooks.shared.evaluationsRun

            for _ in 0 ..< 20 {
                AchievementHooks.shared.schedule(user.userId, app: app)
            }
            await AchievementHooks.shared.waitUntilIdle()

            #expect(AchievementHooks.shared.evaluationsRun == before + 1)
            let row = try #require(try await evaluation(app, userId: user.userId))
            #expect(row.lastEvaluatedAt != nil)
            let unlocks = try await UserAchievement.query(on: app.db)
                .filter(\.$user.$id == user.userId)
                .filter(\.$achievementKey == "start.first_holding")
                .count()
            #expect(unlocks == 1)
        }
    }

    @Test("Schedules arriving during an evaluation re-run it exactly once")
    func scheduleDuringRunRequeuesOnce() async throws {
        try await withApp { app in
            let user = try await register(app, "rerun")
            try await addStock(app, userId: user.userId)
            try await AchievementEvaluation(userId: user.userId, needsBackfill: false).save(on: app.db)
            let before = AchievementHooks.shared.evaluationsRun

            // Hold the user's evaluation lock so the first run cannot finish
            // while more schedules arrive.
            try await app.db.transaction { tx in
                let sql = try #require(tx as? any SQLDatabase)
                try await sql.raw("""
                SELECT user_id FROM achievement_evaluations WHERE user_id = \(bind: user.userId) FOR UPDATE
                """).run()

                AchievementHooks.shared.schedule(user.userId, app: app)
                for _ in 0 ..< 100 where !AchievementHooks.shared.isRunning(user.userId) {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                #expect(AchievementHooks.shared.isRunning(user.userId))
                for _ in 0 ..< 5 {
                    AchievementHooks.shared.schedule(user.userId, app: app)
                }
            }
            await AchievementHooks.shared.waitUntilIdle()

            #expect(AchievementHooks.shared.evaluationsRun == before + 2)
            #expect(!AchievementHooks.shared.isRunning(user.userId))
            let unlocks = try await UserAchievement.query(on: app.db)
                .filter(\.$user.$id == user.userId)
                .filter(\.$achievementKey == "start.first_holding")
                .count()
            #expect(unlocks == 1)
        }
    }

    @Test("A run that wakes after the app shut down evaluates nothing and still goes idle")
    func shutdownSkipsPendingRun() async throws {
        try await DatabaseTestLock.withLock {
            setenv("ACHIEVEMENTS_ENABLED", "1", 1)
            let previousDelay = AchievementHooks.delay
            AchievementHooks.delay = .milliseconds(300)
            defer {
                AchievementHooks.delay = previousDelay
                unsetenv("ACHIEVEMENTS_ENABLED")
            }
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
            } catch {
                try await app.asyncShutdown()
                throw error
            }
            let before = AchievementHooks.shared.evaluationsRun

            AchievementHooks.shared.schedule(UUID(), app: app)
            try await app.asyncShutdown()
            await AchievementHooks.shared.waitUntilIdle()

            #expect(AchievementHooks.shared.evaluationsRun == before)
        }
    }

    @Test("Request.scheduleAchievementCheck schedules every user given")
    func requestSchedulesEachUser() async throws {
        try await withApp { app in
            let ana = try await register(app, "ana")
            let bo = try await register(app, "bo")
            let before = AchievementHooks.shared.evaluationsRun

            let req = Request(application: app, on: app.eventLoopGroup.next())
            req.scheduleAchievementCheck(for: ana.userId, bo.userId, ana.userId)
            await AchievementHooks.shared.waitUntilIdle()

            #expect(AchievementHooks.shared.evaluationsRun == before + 2)
            #expect(try await evaluation(app, userId: ana.userId)?.lastEvaluatedAt != nil)
            #expect(try await evaluation(app, userId: bo.userId)?.lastEvaluatedAt != nil)
        }
    }
}
