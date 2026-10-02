import Fluent
import Foundation
import Redis
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

/// G8 and G9: two pre-existing bugs fixed alongside the pilot gates.
extension StagingGatesTests {
    /// `configure()` leaves Redis off under `.testing`, which also switches the
    /// rate limiter off; RedisKit only builds pools for configurations present
    /// at boot, so this sets one first (as OpsHardeningTests does).
    private func withRedisApp(_ test: (Application) async throws -> Void) async throws {
        try await DatabaseTestLock.withSharedAccess {
            let app = try await Application.make(.testing)
            do {
                let url = Environment.get("REDIS_URL").flatMap { $0.isEmpty ? nil : $0 } ?? "redis://127.0.0.1:6379"
                app.redis.configuration = try RedisConfiguration(url: url)
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

    @Test("broker routes rate-limit per user, not per shared address")
    func brokerRateLimitIsPerUser() async throws {
        try await withRedisApp { app in
            let (first, _) = try await registerTestUser(app: app)
            let (second, _) = try await registerTestUser(app: app)
            for attempt in 1 ... 30 {
                try await app.testing().test(.GET, "v1/brokers", beforeRequest: { $0.headers.bearerAuthorization = .init(token: first) }) { res async throws in
                    #expect(res.status == .ok, "attempt \(attempt): \(res.status)")
                }
            }
            try await app.testing().test(.GET, "v1/brokers", beforeRequest: { $0.headers.bearerAuthorization = .init(token: first) }) { res async throws in
                #expect(res.status == .tooManyRequests, "31st call: \(res.status)")
            }
            // Same (test) address, different user: a bucket of its own.
            try await app.testing().test(.GET, "v1/brokers", beforeRequest: { $0.headers.bearerAuthorization = .init(token: second) }) { res async throws in
                #expect(res.status == .ok, "second user: \(res.status) \(res.body.string)")
            }
        }
    }

    private func addAndSell(_ app: Application, token: String, symbol: String, listId: UUID?, shares: Double, sell: Double, price: Double) async throws {
        var created: StockResponse?
        try await app.testing().test(.POST, "v1/stocks", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(StockRequest(symbol: symbol, shares: shares, buyPrice: 100, buyDate: "2026-01-02", notes: nil, portfolioListId: listId?.uuidString))
        }) { res async throws in
            #expect(res.status == .created, "add \(symbol): \(res.status) \(res.body.string)")
            created = try? res.content.decode(StockResponse.self)
        }
        let stock = try #require(created)
        try await app.testing().test(.POST, "v1/stocks/id/\(stock.id)/sell", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
            try req.content.encode(SellStockRequest(sharesToSell: sell, sellPrice: price, sellDate: "2026-04-10"))
        }) { res async throws in
            #expect(res.status == .ok, "sell \(symbol): \(res.status) \(res.body.string)")
        }
    }

    @Test("manual sells in two portfolios each get their own manual account and cash")
    func manualSellsInTwoPortfolios() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)
            try await grantPro(userId, on: app)
            _ = try await seedInstrument(symbol: "AAPL", on: app.db)
            _ = try await seedInstrument(symbol: "MSFT", on: app.db)

            // Portfolio A is the default the first add creates.
            try await addAndSell(app, token: token, symbol: "AAPL", listId: nil, shares: 5, sell: 1, price: 150)
            let listA = try await ensureDefaultPortfolioListId(userId: userId, on: app.db)
            let listB = PortfolioList(userId: userId, name: "Second")
            try await listB.create(on: app.db)
            let listBId = try listB.requireID()
            try await addAndSell(app, token: token, symbol: "MSFT", listId: listBId, shares: 4, sell: 2, price: 200)

            let accounts = try await Account.query(on: app.db).filter(\.$userId == userId).filter(\.$broker == "manual").all()
            #expect(accounts.count == 2)
            let accountA = try #require(accounts.first { $0.portfolioId == listA })
            let accountB = try #require(accounts.first { $0.portfolioId == listBId })
            #expect(accountA.externalId == "manual-\(userId.uuidString.lowercased())")
            #expect(accountB.externalId == "manual-\(userId.uuidString.lowercased())-\(listBId.uuidString.lowercased())")
            let cashA = try await CashBalance.query(on: app.db).filter(\.$accountId == accountA.requireID()).all().reduce(0) { $0 + $1.balance }
            let cashB = try await CashBalance.query(on: app.db).filter(\.$accountId == accountB.requireID()).all().reduce(0) { $0 + $1.balance }
            #expect(abs(cashA - 150) < 0.001)
            #expect(abs(cashB - 400) < 0.001)
        }
    }
}
