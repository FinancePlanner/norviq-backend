import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("Badge Logic Tests", .serialized)
struct BadgeLogicTests {
    private struct NewsViewTestRequest: Content {
        let newsId: UUID?
        let symbol: String?
        let headline: String
        let url: String?
    }

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withLock {
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

    private func registerTestUser(app: Application) async throws -> (token: String, userId: UUID) {
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        let request = StockPlanBackend.AuthRegisterRequest(
            username: "badge_\(suffix)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "badge+\(suffix)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )

        var response: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        })

        guard let response else {
            throw Abort(.internalServerError, reason: "Auth register did not return a response")
        }
        return (response.token, response.userId)
    }

    private func createHolding(symbol: String, userId: UUID, on db: any Database) async throws {
        let portfolioListId = try await ensureDefaultPortfolioListId(userId: userId, on: db)
        let stock = Stock(
            userId: userId,
            portfolioListId: portfolioListId,
            symbol: symbol,
            shares: 1,
            buyPrice: 100,
            buyDate: Date(timeIntervalSince1970: 1_704_067_200)
        )
        try await stock.save(on: db)
    }

    @Test("Manual holdings earn first purchase and investor badges")
    func manualHoldingsEarnInvestmentBadges() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            for symbol in ["AAPL", "MSFT", "NVDA", "GOOGL", "AMZN"] {
                try await createHolding(symbol: symbol, userId: userId, on: app.db)
            }

            try await app.testing().test(.GET, "v1/badges", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(BadgesListResponse.self)
                let firstPurchase = try #require(payload.badges.first { $0.type == .firstPurchase })
                let investor = try #require(payload.badges.first { $0.type == .investor })
                #expect(firstPurchase.currentTier == .bronze)
                #expect(firstPurchase.currentCount == 5)
                #expect(investor.currentTier == .bronze)
                #expect(investor.currentCount == 5)
            })
        }
    }

    @Test("Badge evaluation persists earned tiers idempotently")
    func badgeEvaluationIsIdempotent() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            for symbol in ["AAPL", "MSFT", "NVDA", "GOOGL", "AMZN"] {
                try await createHolding(symbol: symbol, userId: userId, on: app.db)
            }

            for _ in 0 ..< 2 {
                try await app.testing().test(.GET, "v1/badges", beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                }, afterResponse: { res async throws in
                    #expect(res.status == .ok)
                })
            }

            let persisted = try await UserBadge.query(on: app.db)
                .filter(\.$userId == userId)
                .all()
            #expect(persisted.count == 2)
            #expect(Set(persisted.map(\.badgeType)) == [.firstPurchase, .investor])
        }
    }

    @Test("News view endpoint records one counted activity per article")
    func newsViewRecordsOneCountedActivityPerArticle() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            let body = NewsViewTestRequest(
                newsId: nil,
                symbol: "AAPL",
                headline: "Apple reports earnings",
                url: "https://example.com/apple-earnings"
            )

            for _ in 0 ..< 2 {
                try await app.testing().test(.POST, "v1/news/view", beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(body)
                }, afterResponse: { res async throws in
                    #expect(res.status == .noContent)
                })
            }

            let activities = try await UserActivity.query(on: app.db)
                .filter(\.$userId == userId)
                .filter(\.$type == .newsViewed)
                .all()
            #expect(activities.count == 1)

            try await app.testing().test(.GET, "v1/badges", beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let payload = try res.content.decode(BadgesListResponse.self)
                let newsReader = try #require(payload.badges.first { $0.type == .newsReader })
                #expect(newsReader.currentTier == .bronze)
                #expect(newsReader.currentCount == 1)
            })
        }
    }
}
