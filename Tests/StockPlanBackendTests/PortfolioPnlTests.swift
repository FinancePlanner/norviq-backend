import Fluent
import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor
import VaporTesting

@Suite("Portfolio PnL endpoint", .serialized)
struct PortfolioPnlTests {
    private struct StubMarketDataService: MarketDataService {
        let quotesBySymbol: [String: QuoteResponse]
        let failBatch: Bool

        init(quotesBySymbol: [String: QuoteResponse] = [:], failBatch: Bool = false) {
            self.quotesBySymbol = quotesBySymbol
            self.failBatch = failBatch
        }

        var fmpProvider: (any FMPMarketDataProvider)? {
            nil
        }

        func quote(symbol: String, on _: Request) async throws -> QuoteResponse {
            guard !failBatch, let quote = quotesBySymbol[symbol.uppercased()] else {
                throw Abort(.badGateway, reason: "quote unavailable")
            }
            return quote
        }

        func quoteBatch(symbols: [String], on req: Request) async throws -> QuoteBatchResponse {
            guard !failBatch else { throw Abort(.badGateway, reason: "provider down") }
            var quotes: [QuoteResponse] = []
            for symbol in symbols {
                if let quote = try? await quote(symbol: symbol, on: req) {
                    quotes.append(quote)
                }
            }
            return QuoteBatchResponse(quotes: quotes)
        }

        func history(symbol _: String, from _: String?, to _: String?, on _: Request) async throws -> HistoryResponse {
            throw Abort(.notImplemented)
        }

        func archivedHistory(symbol _: String, from _: String?, to _: String?, on _: Request) async throws -> HistoryResponse {
            throw Abort(.notImplemented)
        }

        func refreshHistory(symbol _: String, from _: String?, to _: String?, on _: Request) async throws -> HistoryResponse {
            throw Abort(.notImplemented)
        }

        func search(query _: String, on _: Request) async throws -> [SearchResultResponse] {
            throw Abort(.notImplemented)
        }

        func fx(pair _: String, on _: Request) async throws -> FxRateResponse {
            throw Abort(.notImplemented)
        }

        func profile(symbol _: String, on _: Request) async throws -> CompanyProfileResponse {
            throw Abort(.notImplemented)
        }

        func basicFinancials(symbol _: String, on _: Request) async throws -> BasicFinancialsResponse {
            throw Abort(.notImplemented)
        }

        func analysis(symbol _: String, on _: Request) async throws -> StockAnalysisMetricsResponse {
            throw Abort(.notImplemented)
        }

        func compare(symbols _: [String], on _: Request) async throws -> [StockAnalysisMetricsResponse] {
            throw Abort(.notImplemented)
        }

        func cashFlowStatement(symbol _: String, limit _: Int?, period _: String?, on _: Request) async throws -> [CashFlowStatementResponse] {
            throw Abort(.notImplemented)
        }

        func incomeStatement(symbol _: String, limit _: Int?, period _: String?, on _: Request) async throws -> [IncomeStatementResponse] {
            throw Abort(.notImplemented)
        }

        func balanceSheetStatement(symbol _: String, limit _: Int?, period _: String?, on _: Request) async throws -> [BalanceSheetStatementResponse] {
            throw Abort(.notImplemented)
        }

        func ratiosTTM(symbol _: String, on _: Request) async throws -> [RatiosTTMResponse] {
            throw Abort(.notImplemented)
        }

        func gradesConsensus(symbol _: String, on _: Request) async throws -> [GradesConsensusResponse] {
            throw Abort(.notImplemented)
        }

        func financialGrowth(symbol _: String, limit _: Int?, period _: String?, on _: Request) async throws -> [FinancialGrowthResponse] {
            throw Abort(.notImplemented)
        }

        func analystEstimates(symbol _: String, period _: String, page _: Int?, limit _: Int?, on _: Request) async throws -> [AnalystEstimatesResponse] {
            throw Abort(.notImplemented)
        }

        func ratios(symbol _: String, limit _: Int?, period _: String?, on _: Request) async throws -> [RatiosResponse] {
            throw Abort(.notImplemented)
        }

        func earnings(symbol _: String, limit _: Int?, on _: Request) async throws -> [EarningsResponse] {
            throw Abort(.notImplemented)
        }

        func earningsCalendar(from _: String?, to _: String?, on _: Request) async throws -> [EarningsResponse] {
            throw Abort(.notImplemented)
        }

        func earningsTranscript(symbol _: String, date _: String?, year _: Int?, quarter _: Int?, on _: Request) async throws -> EarningsTranscriptResponse {
            throw Abort(.notImplemented)
        }

        func historicalSectorPerformance(sector _: String, exchange _: String?, from _: String?, to _: String?, on _: Request) async throws -> [HistoricalSectorPerformanceResponse] {
            throw Abort(.notImplemented)
        }

        func priceChart(symbol _: String, range _: String, on _: Request) async throws -> PriceChartSeries {
            throw Abort(.notImplemented)
        }

        func priceChartComparison(symbols _: [String], range _: String, on _: Request) async throws -> PriceChartComparisonResponse {
            throw Abort(.notImplemented)
        }
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

    private func registerUser(_ suffix: String, on app: Application) async throws -> AuthResponse {
        let request = AuthRegisterRequest(
            username: "pnl_\(suffix)",
            password: "Password123!",
            confirmPassword: "Password123!",
            email: "pnl+\(suffix)@example.com",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var auth: AuthResponse?
        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(request)
        }, afterResponse: { response async throws in
            #expect(response.status == .ok)
            auth = try response.content.decode(AuthResponse.self)
        })
        return try #require(auth)
    }

    private func seedStock(
        userId: UUID,
        portfolioListId: UUID,
        symbol: String,
        shares: Double,
        buyPrice: Double,
        on app: Application
    ) async throws {
        try await Stock(
            userId: userId,
            portfolioListId: portfolioListId,
            symbol: symbol,
            shares: shares,
            buyPrice: buyPrice,
            buyDate: Date(timeIntervalSince1970: 1_700_000_000)
        ).save(on: app.db)
    }

    private func defaultPortfolioListId(userId: UUID, on app: Application) async throws -> UUID {
        try await ensureDefaultPortfolioListId(userId: userId, on: app.db)
    }

    private func fetchPnl(token: String, on app: Application) async throws -> PnlResponse {
        var decoded: PnlResponse?
        try await app.testing().test(.GET, "v1/pnl", beforeRequest: { req in
            req.headers.bearerAuthorization = .init(token: token)
        }, afterResponse: { response async throws in
            #expect(response.status == .ok)
            decoded = try response.content.decode(PnlResponse.self)
        })
        return try #require(decoded)
    }

    @Test("Computes live metrics and aggregates multi-lot symbols")
    func computesLiveMetrics() async throws {
        try await withApp { app in
            let auth = try await registerUser("live", on: app)
            let listId = try await defaultPortfolioListId(userId: auth.userId, on: app)
            // Two AAPL lots: 10 @ 100 and 10 @ 200 -> 20 shares, cost basis 3000, avg 150.
            try await seedStock(userId: auth.userId, portfolioListId: listId, symbol: "AAPL", shares: 10, buyPrice: 100, on: app)
            try await seedStock(userId: auth.userId, portfolioListId: listId, symbol: "aapl", shares: 10, buyPrice: 200, on: app)
            try await seedStock(userId: auth.userId, portfolioListId: listId, symbol: "MSFT", shares: 5, buyPrice: 300, on: app)

            app.marketDataService = StubMarketDataService(quotesBySymbol: [
                "AAPL": QuoteResponse(symbol: "AAPL", currency: "USD", currentPrice: 200, change: 2, percentChange: 1.01, timestamp: 1_700_000_000),
                "MSFT": QuoteResponse(symbol: "MSFT", currency: "USD", currentPrice: 400, change: -4, percentChange: -0.99, timestamp: 1_700_000_000),
            ])

            let pnl = try await fetchPnl(token: auth.token, on: app)

            #expect(pnl.items.count == 2)
            let aapl = try #require(pnl.items.first { $0.symbol == "AAPL" })
            #expect(aapl.shares == 20)
            #expect(aapl.buyPrice == 150)
            #expect(aapl.costBasis == 3000)
            #expect(aapl.currentPrice == 200)
            #expect(aapl.marketValue == 4000)
            #expect(aapl.unrealizedPnl == 1000)
            #expect(aapl.unrealizedPnlPercent.map { abs($0 - 33.33) < 0.01 } == true)
            #expect(aapl.dayChange == 40)
            #expect(aapl.dayChangePercent == 1.01)

            let msft = try #require(pnl.items.first { $0.symbol == "MSFT" })
            #expect(msft.marketValue == 2000)
            #expect(msft.unrealizedPnl == 500)
            #expect(msft.dayChange == -20)

            // No cash seeded: weights are shares of total holdings value (6000).
            #expect(aapl.weightPercent.map { abs($0 - 66.67) < 0.01 } == true)
            #expect(msft.weightPercent.map { abs($0 - 33.33) < 0.01 } == true)
            // Sorted by market value descending.
            #expect(pnl.items.first?.symbol == "AAPL")
        }
    }

    @Test("Falls back to cost basis when quotes are unavailable")
    func quoteOutageFallsBack() async throws {
        try await withApp { app in
            let auth = try await registerUser("outage", on: app)
            let listId = try await defaultPortfolioListId(userId: auth.userId, on: app)
            try await seedStock(userId: auth.userId, portfolioListId: listId, symbol: "NVDA", shares: 4, buyPrice: 500, on: app)

            app.marketDataService = StubMarketDataService(failBatch: true)

            let pnl = try await fetchPnl(token: auth.token, on: app)

            let nvda = try #require(pnl.items.first { $0.symbol == "NVDA" })
            #expect(nvda.costBasis == 2000)
            #expect(nvda.currentPrice == nil)
            #expect(nvda.marketValue == 2000)
            #expect(nvda.unrealizedPnl == 0)
            #expect(nvda.dayChange == nil)
            #expect(nvda.dayChangePercent == nil)
            #expect(nvda.weightPercent == 100)
        }
    }

    @Test("Scopes holdings by portfolioListId filter")
    func portfolioListFilter() async throws {
        try await withApp { app in
            let auth = try await registerUser("filter", on: app)
            let defaultList = try await defaultPortfolioListId(userId: auth.userId, on: app)
            let secondList = PortfolioList(userId: auth.userId, name: "Second", isDefault: false)
            try await secondList.save(on: app.db)
            let secondListId = try #require(secondList.id)

            try await seedStock(userId: auth.userId, portfolioListId: defaultList, symbol: "AAPL", shares: 1, buyPrice: 100, on: app)
            try await seedStock(userId: auth.userId, portfolioListId: secondListId, symbol: "TSLA", shares: 1, buyPrice: 250, on: app)

            app.marketDataService = StubMarketDataService(failBatch: true)

            var decoded: PnlResponse?
            try await app.testing().test(.GET, "v1/pnl?portfolioListId=\(secondListId.uuidString)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: auth.token)
            }, afterResponse: { response async throws in
                #expect(response.status == .ok)
                decoded = try response.content.decode(PnlResponse.self)
            })
            let pnl = try #require(decoded)

            #expect(pnl.items.count == 1)
            #expect(pnl.items.first?.symbol == "TSLA")
        }
    }
}
