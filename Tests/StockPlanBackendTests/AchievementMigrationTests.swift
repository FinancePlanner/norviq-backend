import Fluent
import FluentSQL
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// The achievements tables, their migration over existing data, and the
/// leaderboard-excluded XP flag, against a real database.
@Suite("Achievement migration", .serialized)
struct AchievementMigrationTests {
    private func withApp(achievements: Bool = false, _ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            setenv("SOCIAL_ENABLED", "1", 1)
            setenv("SOCIAL_LEADERBOARDS_ENABLED", "1", 1)
            if achievements {
                setenv("ACHIEVEMENTS_ENABLED", "1", 1)
            } else {
                unsetenv("ACHIEVEMENTS_ENABLED")
            }
            defer {
                unsetenv("SOCIAL_LEADERBOARDS_ENABLED")
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

    private func register(_ app: Application, _ id: String) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "ach_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "ach+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
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

    @Test("Existing users are marked for backfill")
    func existingUsersAreMarkedForBackfill() async throws {
        try await withApp { app in
            let user = try await register(app, "backfill")
            try await CreateAchievementTables().revert(on: app.db)
            try await CreateAchievementTables().prepare(on: app.db)
            let row = try await AchievementEvaluation.query(on: app.db)
                .filter(\.$userId == user.userId)
                .first()
            #expect(row?.needsBackfill == true)
        }
    }

    @Test("Legacy badges are copied as achievements")
    func legacyBadgesAreCopied() async throws {
        try await withApp { app in
            let user = try await register(app, "legacy")
            let earned = Date(timeIntervalSince1970: 1_700_000_000)
            try await UserBadge(userId: user.userId, badgeType: .firstPurchase, tier: .silver, earnedAt: earned)
                .save(on: app.db)
            try await CreateAchievementTables().revert(on: app.db)
            try await CreateAchievementTables().prepare(on: app.db)
            let rows = try await UserAchievement.query(on: app.db)
                .filter(\.$user.$id == user.userId)
                .all()
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            #expect(row.achievementKey == "legacy.\(BadgeType.firstPurchase.rawValue)")
            #expect(row.tier == "silver")
            #expect(row.source == AchievementSource.legacyBadge.rawValue)
            let seen = try #require(row.seenAt)
            #expect(abs(seen.timeIntervalSince(earned)) < 1)
        }
    }

    @Test("Leaderboard ignores excluded XP but the total counts it")
    func leaderboardIgnoresExcludedXP() async throws {
        try await withApp { app in
            let user = try await register(app, "xp")
            try await XPService.award(.badgeEarned, points: 100, to: user.userId, dedupeKey: "t:excluded",
                                      excludeFromLeaderboard: true, on: app.db)
            try await XPService.award(.badgeEarned, points: 10, to: user.userId, dedupeKey: "t:counted", on: app.db)
            let interval = DateInterval(start: Date().addingTimeInterval(-3600), end: Date().addingTimeInterval(3600))
            let byUser = try await XPService.xpByUser([user.userId], in: interval, on: app.db)
            #expect(byUser[user.userId] == 10)
            let summary = try await XPService.summary(for: user.userId, now: Date(), timeZone: GamificationCalendar.utc, on: app.db)
            #expect(summary.total == 110)
        }
    }

    @Test("Social config exposes the achievements flag")
    func configExposesAchievementsFlag() async throws {
        for enabled in [true, false] {
            try await withApp(achievements: enabled) { app in
                let user = try await register(app, "cfg\(enabled)")
                var headers = HTTPHeaders()
                headers.bearerAuthorization = BearerAuthorization(token: user.token)
                try await app.testing().test(.GET, "v1/social/config", headers: headers) { res async throws in
                    #expect(res.status == .ok)
                    let dto = try res.content.decode(SocialConfigDTO.self)
                    #expect(dto.achievements == enabled)
                    #expect(res.body.string.contains("\"achievements\":\(enabled)"))
                }
            }
        }
    }
}
