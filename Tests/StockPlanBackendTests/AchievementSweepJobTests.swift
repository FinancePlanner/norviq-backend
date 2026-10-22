import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// The hourly sweep: due-user selection, batching and the feature flag.
@Suite("Achievement sweep job", .serialized)
struct AchievementSweepJobTests {
    private func withApp(flag: Bool = true, _ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            setenv("SOCIAL_ENABLED", "1", 1)
            setenv("ACHIEVEMENTS_ENABLED", flag ? "1" : "0", 1)
            defer {
                unsetenv("SOCIAL_ENABLED")
                unsetenv("ACHIEVEMENTS_ENABLED")
            }
            let app = try await Application.make(.testing)
            do {
                try await configure(app)
                try await app.autoMigrate()
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

    private func register(_ app: Application, _ id: String) async throws -> UUID {
        let request = AuthRegisterRequest(
            username: "achsw_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "achsw+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var response: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        })
        return try #require(response).userId
    }

    private func evaluation(_ app: Application, _ userId: UUID) async throws -> AchievementEvaluation? {
        try await AchievementEvaluation.query(on: app.db).filter(\.$userId == userId).first()
    }

    private func addStock(_ app: Application, userId: UUID) async throws {
        let listId = try await ensureDefaultPortfolioListId(userId: userId, on: app.db)
        try await Stock(
            userId: userId, portfolioListId: listId, symbol: "AAPL", shares: 1, buyPrice: 100,
            buyDate: Date().addingTimeInterval(-10 * 86400)
        ).save(on: app.db)
    }

    @Test("Sweeps due users in batches")
    func runOnceSweepsDueUsers() async throws {
        try await withApp { app in
            let ids = [try await register(app, "b1"), try await register(app, "b2"), try await register(app, "b3")]
            // Everyone else is fresh, so only our three are due.
            try await AchievementEvaluation.query(on: app.db).set(\.$lastSweptAt, to: Date()).update()
            try await AchievementEvaluation.query(on: app.db).filter(\.$userId ~~ ids).set(\.$lastSweptAt, to: nil).update()
            await AchievementSweepJob(batchSize: 2).runOnce(app)
            var swept = 0
            for id in ids where try await evaluation(app, id)?.lastSweptAt != nil { swept += 1 }
            #expect(swept == 2)
            await AchievementSweepJob(batchSize: 2).runOnce(app)
            for id in ids {
                #expect(try await evaluation(app, id)?.lastSweptAt != nil)
            }
        }
    }

    @Test("Recently swept users are skipped")
    func recentlySweptSkipped() async throws {
        try await withApp { app in
            let id = try await register(app, "c1")
            let recent = Date().addingTimeInterval(-3600)
            let row = AchievementEvaluation(userId: id)
            row.lastSweptAt = recent
            try await row.save(on: app.db)
            try await addStock(app, userId: id)

            let job = AchievementSweepJob(batchSize: 10000)
            await job.runOnce(app)

            let unlocks = try await UserAchievement.query(on: app.db).filter(\.$user.$id == id).count()
            #expect(unlocks == 0)
            #expect(try await evaluation(app, id)?.lastSweptAt?.timeIntervalSince(recent) ?? 1 < 1)

            // 25h later the same user is due.
            await job.runOnce(app, now: Date().addingTimeInterval(25 * 3600))
            let after = try await UserAchievement.query(on: app.db).filter(\.$user.$id == id).count()
            #expect(after > 0)
        }
    }

    @Test("Flag off does nothing")
    func flagOffNoop() async throws {
        try await withApp(flag: false) { app in
            let id = try await register(app, "d1")
            await AchievementSweepJob().runOnce(app)
            let row = try await evaluation(app, id)
            #expect(row?.lastSweptAt == nil)
            #expect(try await UserAchievement.query(on: app.db).filter(\.$user.$id == id).count() == 0)
        }
    }

    @Test("A row created by a failed sweep follows the activation rule")
    func stampSweptRespectsActivation() async throws {
        try await withApp { app in
            let early = try await register(app, "e1")
            let activation = Date()
            try await AchievementService.ensureActivated(at: activation, on: app.db)
            let late = try await register(app, "e2")
            #expect(try await evaluation(app, early) == nil)
            #expect(try await evaluation(app, late) == nil)

            let now = activation.addingTimeInterval(60)
            await AchievementSweepJob.stampSwept(userId: early, now: now, app: app)
            await AchievementSweepJob.stampSwept(userId: late, now: now, app: app)

            let earlyRow = try #require(try await evaluation(app, early))
            #expect(earlyRow.needsBackfill == true)
            #expect(earlyRow.lastSweptAt != nil)
            let lateRow = try #require(try await evaluation(app, late))
            #expect(lateRow.needsBackfill == false)
            #expect(lateRow.lastSweptAt != nil)
        }
    }
}
