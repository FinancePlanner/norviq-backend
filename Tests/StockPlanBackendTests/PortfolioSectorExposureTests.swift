import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import VaporTesting

@Suite("Portfolio Sector Exposure Tests", .serialized)
struct PortfolioSectorExposureTests {
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

    private func registerUser(on app: Application, identifier: String) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "sector_\(identifier)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "sector+\(identifier)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
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

    @Test("sector exposure groups holdings and computes S&P 500 overweight")
    func sectorExposureGroupsHoldingsAndComputesOverweight() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "grouping")
            let listId = try await ensureDefaultPortfolioListId(userId: auth.userId, on: app.db)

            try await seedStock(symbol: "AAPL", shares: 10, buyPrice: 150, userId: auth.userId, listId: listId, on: app.db)
            try await seedStock(symbol: "MSFT", shares: 5, buyPrice: 300, userId: auth.userId, listId: listId, on: app.db)
            try await seedStock(symbol: "XOM", shares: 10, buyPrice: 40, userId: auth.userId, listId: listId, on: app.db)
            try await seedQuote(symbol: "AAPL", price: 200, on: app.db)
            try await seedQuote(symbol: "MSFT", price: 400, on: app.db)
            try await seedQuote(symbol: "XOM", price: 50, on: app.db)
            try await seedProfile(symbol: "AAPL", industry: "Technology", on: app.db)
            try await seedProfile(symbol: "MSFT", industry: "Technology", on: app.db)
            try await seedProfile(symbol: "XOM", industry: "Energy", on: app.db)

            let account = Account(
                userId: auth.userId,
                externalId: "cash-\(auth.userId.uuidString)",
                broker: "manual",
                displayName: "Manual Cash",
                baseCurrency: "USD"
            )
            try await account.save(on: app.db)
            try await CashBalance(
                accountId: account.requireID(),
                currency: "USD",
                balance: 1000,
                asOf: Date()
            ).save(on: app.db)

            try await app.testing().test(.GET, "v1/portfolio/sector-exposure", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(PortfolioSectorExposureResponse.self)
                #expect(response.investedValue == 4500)
                #expect(response.cashBalance == 1000)
                #expect(response.totalValue == 5500)

                let technology = try #require(response.sectors.first { $0.sector == "Information Technology" })
                #expect(technology.value == 4000)
                #expect(abs(technology.weightPercent - 88.89) < 0.01)
                #expect(technology.benchmarkWeightPercent == 38.6)
                #expect(abs((technology.overweightPercent ?? 0) - 50.29) < 0.01)
                #expect(technology.holdings.map(\.symbol) == ["AAPL", "MSFT"])

                let energy = try #require(response.sectors.first { $0.sector == "Energy" })
                #expect(energy.value == 500)
                #expect(abs(energy.weightPercent - 11.11) < 0.01)
            })
        }
    }

    @Test("sector exposure scopes results to requested portfolio list")
    func sectorExposureScopesToRequestedPortfolioList() async throws {
        try await withApp { app in
            let auth = try await registerUser(on: app, identifier: "scoped")
            let defaultListId = try await ensureDefaultPortfolioListId(userId: auth.userId, on: app.db)
            let satelliteList = PortfolioList(userId: auth.userId, name: "Satellite", isDefault: false)
            try await satelliteList.save(on: app.db)
            let satelliteListId = try satelliteList.requireID()

            try await seedStock(symbol: "AAPL", shares: 10, buyPrice: 100, userId: auth.userId, listId: defaultListId, on: app.db)
            try await seedStock(symbol: "XOM", shares: 10, buyPrice: 50, userId: auth.userId, listId: satelliteListId, on: app.db)
            try await seedProfile(symbol: "AAPL", industry: "Technology", on: app.db)
            try await seedProfile(symbol: "XOM", industry: "Energy", on: app.db)

            try await app.testing().test(.GET, "v1/portfolio/sector-exposure?portfolioListId=\(satelliteListId.uuidString)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let response = try res.content.decode(PortfolioSectorExposureResponse.self)
                #expect(response.sectors.map(\.sector) == ["Energy"])
                #expect(response.sectors.first?.weightPercent == 100)
            })
        }
    }

    private func seedStock(
        symbol: String,
        shares: Double,
        buyPrice: Double,
        userId: UUID,
        listId: UUID,
        on db: any Database
    ) async throws {
        let stock = Stock(
            userId: userId,
            portfolioListId: listId,
            symbol: symbol,
            shares: shares,
            buyPrice: buyPrice,
            buyDate: Date(timeIntervalSince1970: 1_704_067_200)
        )
        try await stock.save(on: db)
    }

    private func seedQuote(symbol: String, price: Double, on db: any Database) async throws {
        try await QuoteCache(
            provider: "test",
            symbol: symbol,
            currency: "USD",
            price: price,
            asOf: Date()
        ).save(on: db)
    }

    private func seedProfile(symbol: String, industry: String, on db: any Database) async throws {
        try await ProfileCache(
            provider: "test",
            symbol: symbol,
            finnhubIndustry: industry
        ).save(on: db)
    }
}
