import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

/// `/v1/achievements` end to end: flag, wire shape, language, unseen/seen,
/// showcase validation.
@Suite("Achievement routes", .serialized)
struct AchievementRouteTests {
    private func withApp(enabled: Bool = true, _ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
            if enabled { setenv("ACHIEVEMENTS_ENABLED", "1", 1) } else { unsetenv("ACHIEVEMENTS_ENABLED") }
            setenv("SOCIAL_ENABLED", "1", 1)
            defer {
                unsetenv("ACHIEVEMENTS_ENABLED")
                unsetenv("SOCIAL_ENABLED")
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
            username: "achr_\(id)", password: "Password123!", confirmPassword: "Password123!",
            email: "achr+\(id)@example.com", dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
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

    private func addFirstHolding(_ app: Application, userId: UUID) async throws {
        let listId = try await ensureDefaultPortfolioListId(userId: userId, on: app.db)
        try await Stock(
            userId: userId, portfolioListId: listId, symbol: "AAPL", shares: 1, buyPrice: 100,
            buyDate: Date().addingTimeInterval(-10 * 86400)
        ).save(on: app.db)
        let onboarding = try await OnboardingState.query(on: app.db).filter(\.$userId == userId).first()
            ?? { let state = OnboardingState(); state.userId = userId; return state }()
        onboarding.firstHoldingAt = Date()
        try await onboarding.save(on: app.db)
    }

    private func call<T: Decodable>(
        _ app: Application, _ method: HTTPMethod, _ path: String, token: String,
        language: String? = nil, body: (any Content)? = nil, status: HTTPStatus = .ok, as _: T.Type
    ) async throws -> T {
        var out: T?
        try await app.testing().test(method, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            if let language { req.headers.replaceOrAdd(name: .acceptLanguage, value: language) }
            if let body { try req.content.encode(body) }
        }, afterResponse: { res async throws in
            #expect(res.status == status)
            if res.status == .ok { out = try res.content.decode(T.self) }
        })
        return try #require(out)
    }

    private func status(
        _ app: Application, _ method: HTTPMethod, _ path: String, token: String, body: (any Content)? = nil
    ) async throws -> HTTPStatus {
        var result: HTTPStatus = .internalServerError
        try await app.testing().test(method, path, beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            if let body { try req.content.encode(body) }
        }, afterResponse: { res async throws in result = res.status })
        return result
    }

    private func insert(_ app: Application, userId: UUID, key: String, tier: String = "", source: AchievementSource = .live, seen: Bool = false, at: Date = Date()) async throws {
        let row = UserAchievement(userId: userId, achievementKey: key, tier: tier, unlockedAt: at, source: source)
        if seen { row.seenAt = at }
        try await row.save(on: app.db)
    }

    @Test("All four routes are 404 while the flag is off")
    func flagOff404() async throws {
        try await withApp(enabled: false) { app in
            let user = try await register(app, "off")
            #expect(try await status(app, .GET, "v1/achievements", token: user.token) == .notFound)
            #expect(try await status(app, .GET, "v1/achievements/unseen", token: user.token) == .notFound)
            #expect(try await status(app, .POST, "v1/achievements/seen", token: user.token, body: AchievementSeenBody(ids: [])) == .notFound)
            #expect(try await status(app, .PUT, "v1/achievements/showcase", token: user.token, body: AchievementShowcaseBody(items: [])) == .notFound)
        }
    }

    @Test("Listing has the documented shape")
    func listShape() async throws {
        try await withApp { app in
            let user = try await register(app, "shape")
            try await addFirstHolding(app, userId: user.userId)
            let list = try await call(app, .GET, "v1/achievements", token: user.token, as: AchievementsResponseDTO.self)

            let first = try #require(list.achievements.first { $0.key == "start.first_holding" })
            #expect(first.state == "earned")
            #expect(first.currentTier == "")
            #expect(first.progress == nil)
            #expect(first.tiers.first?.unlockId != nil)

            let checkIn = try #require(list.achievements.first { $0.key == "discipline.check_in" })
            #expect(checkIn.state == "locked")
            #expect(checkIn.progress?.current == 0)
            #expect(checkIn.progress?.target == 7)

            let founding = try #require(list.achievements.first { $0.key == "hidden.founding_member" })
            #expect(founding.state == "earned")
            #expect(founding.title == "Founding Member")

            for perf in list.achievements where perf.isPerformance { #expect(perf.progress == nil) }
            #expect(!list.categories.contains { $0.key == "classic" })
            #expect(!list.achievements.contains { $0.key.hasPrefix("legacy.") })
            #expect(list.summary.unlocked >= 1)
            #expect(list.categories.map(\.key) == AchievementCategory.allCases.filter { $0 != .classic }.map(\.rawValue))
        }
    }

    @Test("A hidden achievement stays masked until earned")
    func hiddenMasked() async throws {
        try await withApp { app in
            let original = AchievementMetrics.foundingLimit
            AchievementMetrics.foundingLimit = 0
            defer { AchievementMetrics.foundingLimit = original }
            let user = try await register(app, "hidden")
            let list = try await call(app, .GET, "v1/achievements", token: user.token, as: AchievementsResponseDTO.self)
            #expect(!list.achievements.contains { $0.key == "hidden.founding_member" })
            #expect(!list.achievements.contains { $0.key.contains("founding") })
            let founding = try #require(list.achievements.first { $0.state == "hidden" })
            #expect(founding.key == "hidden.1")
            #expect(founding.title == "???")
            #expect(founding.iconKey == "lock")
            #expect(founding.progress == nil)
            #expect(founding.tiers.allSatisfy { $0.threshold == nil && $0.xp == 0 })
            // The opaque key is not a showcase handle.
            let rejected = try await status(app, .PUT, "v1/achievements/showcase", token: user.token,
                                            body: AchievementShowcaseBody(items: [.init(key: "hidden.1", tier: "")]))
            #expect(rejected == .badRequest)
            #expect(list.summary.hiddenRemaining >= 1)
        }
    }

    @Test("Accept-Language pt-PT returns Portuguese copy")
    func portuguese() async throws {
        try await withApp { app in
            let user = try await register(app, "pt")
            let list = try await call(app, .GET, "v1/achievements", token: user.token, language: "pt-PT", as: AchievementsResponseDTO.self)
            let item = try #require(list.achievements.first { $0.key == "start.first_holding" })
            let expected = try #require(AchievementCatalogue.definition("start.first_holding")?.copy[.pt]?.title)
            #expect(item.title == expected)
        }
    }

    @Test("Unseen lists live unlocks oldest first; seen clears only the caller's")
    func unseenThenSeen() async throws {
        try await withApp { app in
            let user = try await register(app, "unseen")
            let other = try await register(app, "unseen2")
            let now = Date()
            try await insert(app, userId: user.userId, key: "start.first_holding", at: now.addingTimeInterval(-10))
            try await insert(app, userId: user.userId, key: "start.first_budget", at: now.addingTimeInterval(-5))
            try await insert(app, userId: other.userId, key: "start.first_holding")
            let otherRow = try #require(try await UserAchievement.query(on: app.db).filter(\.$user.$id == other.userId).first())

            let unseen = try await call(app, .GET, "v1/achievements/unseen", token: user.token, as: [AchievementUnlockDTO].self)
            #expect(unseen.map(\.key) == ["start.first_holding", "start.first_budget"])
            #expect(unseen.first?.xp == 25)

            let one = try #require(unseen.first?.id)
            #expect(try await status(app, .POST, "v1/achievements/seen", token: user.token,
                                     body: AchievementSeenBody(ids: [one, try #require(otherRow.id)])) == .noContent)
            let after = try await call(app, .GET, "v1/achievements/unseen", token: user.token, as: [AchievementUnlockDTO].self)
            #expect(after.map(\.key) == ["start.first_budget"])

            let untouched = try #require(try await UserAchievement.find(otherRow.id, on: app.db))
            #expect(untouched.seenAt == nil)
        }
    }

    @Test("Backfilled unlocks never appear in unseen")
    func backfilledNotUnseen() async throws {
        try await withApp { app in
            let user = try await register(app, "backfill")
            try await AchievementEvaluation(userId: user.userId, needsBackfill: true).save(on: app.db)
            try await addFirstHolding(app, userId: user.userId)
            try await insert(app, userId: user.userId, key: "start.first_budget", source: .backfill)
            _ = try await call(app, .GET, "v1/achievements", token: user.token, as: AchievementsResponseDTO.self)
            #expect(try await UserAchievement.query(on: app.db).filter(\.$user.$id == user.userId).count() >= 2)
            let unseen = try await call(app, .GET, "v1/achievements/unseen", token: user.token, as: [AchievementUnlockDTO].self)
            #expect(unseen.isEmpty)
        }
    }

    @Test("Showcase validation and ranks")
    func showcaseValidation() async throws {
        try await withApp { app in
            let user = try await register(app, "showcase")
            for key in ["start.first_holding", "start.first_budget", "start.first_goal", "hidden.founding_member"] {
                try await insert(app, userId: user.userId, key: key, seen: true)
            }
            func put(_ items: [AchievementShowcaseItem]) async throws -> HTTPStatus {
                try await status(app, .PUT, "v1/achievements/showcase", token: user.token, body: AchievementShowcaseBody(items: items))
            }
            let four = ["start.first_holding", "start.first_budget", "start.first_goal", "hidden.founding_member"]
                .map { AchievementShowcaseItem(key: $0, tier: "") }
            #expect(try await put(four) == .badRequest)
            #expect(try await put([four[0], four[0]]) == .badRequest)
            #expect(try await put([AchievementShowcaseItem(key: "discipline.check_in", tier: "gold")]) == .badRequest)

            let result = try await call(
                app, .PUT, "v1/achievements/showcase", token: user.token,
                body: AchievementShowcaseBody(items: [four[1], four[0]]), as: AchievementsResponseDTO.self
            )
            func ranks(_ list: AchievementsResponseDTO) -> [String: Int] {
                var out: [String: Int] = [:]
                for item in list.achievements { for tier in item.tiers { if let rank = tier.showcaseRank { out[item.key] = rank } } }
                return out
            }
            #expect(ranks(result) == ["start.first_budget": 1, "start.first_holding": 2])

            let again = try await call(app, .GET, "v1/achievements", token: user.token, as: AchievementsResponseDTO.self)
            #expect(ranks(again) == ["start.first_budget": 1, "start.first_holding": 2])

            let cleared = try await call(
                app, .PUT, "v1/achievements/showcase", token: user.token,
                body: AchievementShowcaseBody(items: []), as: AchievementsResponseDTO.self
            )
            #expect(ranks(cleared).isEmpty)
        }
    }
}
