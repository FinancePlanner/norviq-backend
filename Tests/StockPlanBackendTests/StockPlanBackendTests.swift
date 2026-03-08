@testable import StockPlanBackend
import VaporTesting
import Testing
import Fluent
import NIOCore
import Foundation

@Suite("App Tests with DB", .serialized)
struct StockPlanBackendTests {
    private struct TestHealthResponse: Decodable {
        let status: String
    }

    private func withApp(_ test: (Application) async throws -> ()) async throws {
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
        let register = AuthRegisterRequest(
            username: "test_user",
            password: "Password123",
            email: "test@example.com",
            firstName: "Test",
            lastName: "User",
            dateOfBirth: Date(timeIntervalSince1970: 946_684_800)
        )
        var response: AuthResponse?

        try await app.testing().test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(register)
        }, afterResponse: { res async throws in
            #expect(res.status == .ok)
            response = try res.content.decode(AuthResponse.self)
        })

        guard let response else {
            throw Abort(.internalServerError, reason: "Auth register did not return a response")
        }
        return (response.token, response.userId)
    }

    private func makeTestMarketService(
        state: TestMarketProviderState,
        quoteTTLSeconds: Int = 3_600,
        historyTTLSeconds: Int = 3_600,
        searchTTLSeconds: Int = 3_600,
        fxTTLSeconds: Int = 3_600
    ) -> any MarketDataService {
        DefaultMarketDataService(
            provider: TestMarketDataProvider(state: state),
            cacheConfig: .init(
                quoteTTLSeconds: quoteTTLSeconds,
                historyTTLSeconds: historyTTLSeconds,
                searchTTLSeconds: searchTTLSeconds,
                fxTTLSeconds: fxTTLSeconds,
                defaultCurrency: "USD"
            )
        )
    }

    @Test("Test Hello World Route")
    func helloWorld() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/hello", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "Hello, world!")
            })
        }
    }

    @Test("Health endpoint returns ok")
    func healthEndpoint() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "health", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(TestHealthResponse.self)
                #expect(body.status == "ok")
            })
        }
    }

    @Test("Market quote endpoint requires authentication")
    func quoteRequiresAuth() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(state: state)

            try await app.testing().test(.GET, "v1/quote/AAPL", afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Quote uses cache after first fetch")
    func quoteUsesCache() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(state: state)
            let (token, _) = try await registerTestUser(app: app)

            var first: QuoteResponse?
            var second: QuoteResponse?

            try await app.testing().test(.GET, "v1/quote/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode(QuoteResponse.self)
            })

            try await app.testing().test(.GET, "v1/quote/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                second = try res.content.decode(QuoteResponse.self)
            })

            #expect(first?.symbol == "AAPL")
            #expect(second?.symbol == "AAPL")
            #expect(first?.price == second?.price)
            #expect(await state.quoteCalls() == 1)
        }
    }

    @Test("Quote batch normalizes, deduplicates, and caches symbols")
    func quoteBatchUsesCache() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(state: state)
            let (token, _) = try await registerTestUser(app: app)

            var first: QuoteBatchResponse?
            var second: QuoteBatchResponse?

            try await app.testing().test(.GET, "v1/quote/batch?symbols=AAPL, msft ,aapl", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode(QuoteBatchResponse.self)
            })

            try await app.testing().test(.GET, "v1/quote/batch?symbols=MSFT,AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                second = try res.content.decode(QuoteBatchResponse.self)
            })

            #expect(first?.quotes.count == 2)
            #expect(second?.quotes.count == 2)
            #expect(Set(first?.quotes.map(\.symbol) ?? []) == Set(["AAPL", "MSFT"]))
            #expect(Set(second?.quotes.map(\.symbol) ?? []) == Set(["AAPL", "MSFT"]))
            #expect(await state.quoteCalls() == 2)
        }
    }

    @Test("History uses cache after first fetch")
    func historyUsesCache() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(
                state: state,
                quoteTTLSeconds: 3_600,
                historyTTLSeconds: 86_400,
                searchTTLSeconds: 3_600,
                fxTTLSeconds: 3_600
            )
            let (token, _) = try await registerTestUser(app: app)

            var first: HistoryResponse?
            var second: HistoryResponse?

            try await app.testing().test(.GET, "v1/history/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode(HistoryResponse.self)
            })

            try await app.testing().test(.GET, "v1/history/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                second = try res.content.decode(HistoryResponse.self)
            })

            #expect(first?.symbol == "AAPL")
            #expect(second?.symbol == "AAPL")
            #expect(first?.bars.count == 1)
            #expect(second?.bars.count == 1)
            #expect(await state.historyCalls() == 1)
        }
    }

    @Test("Search uses cache after first fetch")
    func searchUsesCache() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(state: state)
            let (token, _) = try await registerTestUser(app: app)

            var first: [SearchResultResponse] = []
            var second: [SearchResultResponse] = []

            try await app.testing().test(.GET, "v1/search?q=AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode([SearchResultResponse].self)
            })

            try await app.testing().test(.GET, "v1/search?q=AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                second = try res.content.decode([SearchResultResponse].self)
            })

            #expect(first.count == 1)
            #expect(second.count == 1)
            #expect(first.first?.symbol == "AAPL")
            #expect(second.first?.symbol == "AAPL")
            #expect(await state.searchCalls() == 1)
        }
    }

    @Test("Quote returns stale DB cache if provider fails")
    func quoteFallsBackToStaleDatabaseCache() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(
                state: state,
                quoteTTLSeconds: 1,
                historyTTLSeconds: 3_600,
                searchTTLSeconds: 3_600,
                fxTTLSeconds: 3_600
            )
            let (token, _) = try await registerTestUser(app: app)

            let stale = QuoteCache(
                provider: "ibkr",
                symbol: "AAPL",
                currency: "USD",
                price: 123.45,
                asOf: Date().addingTimeInterval(-3_600)
            )
            try await stale.save(on: app.db)
            await state.setFailQuote(true)

            var response: QuoteResponse?
            try await app.testing().test(.GET, "v1/quote/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                response = try res.content.decode(QuoteResponse.self)
            })

            #expect(response?.symbol == "AAPL")
            #expect(response?.price == 123.45)
            #expect(await state.quoteCalls() == 1)
        }
    }

    @Test("News feed returns tracked symbols and respects limit")
    func newsFeedReturnsTrackedAndLimitedResults() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)

            let stock = Stock(
                userId: userId,
                symbol: "AAPL",
                shares: 3,
                buyPrice: 100,
                buyDate: Date()
            )
            try await stock.save(on: app.db)

            let watchlist = WatchlistItem(userId: userId, symbol: "MSFT")
            try await watchlist.save(on: app.db)

            let trackedRecent = NewsItem(
                userId: userId,
                symbol: "AAPL",
                headline: "Tracked recent",
                source: "Reuters",
                url: nil,
                summary: nil,
                publishedAt: Date()
            )
            let trackedOlder = NewsItem(
                userId: userId,
                symbol: "MSFT",
                headline: "Tracked older",
                source: "Bloomberg",
                url: nil,
                summary: nil,
                publishedAt: Date().addingTimeInterval(-3_600)
            )
            let untrackedNewest = NewsItem(
                userId: userId,
                symbol: "TSLA",
                headline: "Untracked newest",
                source: "WSJ",
                url: nil,
                summary: nil,
                publishedAt: Date().addingTimeInterval(3_600)
            )

            try await trackedRecent.save(on: app.db)
            try await trackedOlder.save(on: app.db)
            try await untrackedNewest.save(on: app.db)

            var allFeed: [NewsItemResponse] = []
            var limitedFeed: [NewsItemResponse] = []

            try await app.testing().test(.GET, "v1/news/feed?limit=10", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                allFeed = try res.content.decode([NewsItemResponse].self)
            })

            try await app.testing().test(.GET, "v1/news/feed?limit=1", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                limitedFeed = try res.content.decode([NewsItemResponse].self)
            })

            #expect(allFeed.count == 2)
            #expect(Set(allFeed.map(\.symbol)) == Set(["AAPL", "MSFT"]))
            #expect(!allFeed.contains { $0.symbol == "TSLA" })

            #expect(limitedFeed.count == 1)
            #expect(limitedFeed.first?.symbol == "AAPL")
        }
    }

    @Test("Dashboard returns aggregate metrics for current user")
    func dashboardReturnsAggregateMetrics() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app)

            let aapl = Stock(
                userId: userId,
                symbol: "AAPL",
                shares: 10,
                buyPrice: 100,
                buyDate: Date()
            )
            let msft = Stock(
                userId: userId,
                symbol: "MSFT",
                shares: 5,
                buyPrice: 200,
                buyDate: Date()
            )
            try await aapl.save(on: app.db)
            try await msft.save(on: app.db)

            let aaplQuote = QuoteCache(
                provider: "ibkr",
                symbol: "AAPL",
                currency: "USD",
                price: 120,
                asOf: Date()
            )
            let msftQuote = QuoteCache(
                provider: "ibkr",
                symbol: "MSFT",
                currency: "USD",
                price: 180,
                asOf: Date()
            )
            try await aaplQuote.save(on: app.db)
            try await msftQuote.save(on: app.db)

            let watchlist = WatchlistItem(userId: userId, symbol: "GOOGL")
            try await watchlist.save(on: app.db)

            let research = ResearchNote(
                userId: userId,
                symbol: "AAPL",
                title: "Q1 review",
                thesis: "Strong ecosystem",
                risks: "Valuation",
                catalysts: "Services growth",
                referenceLinks: nil
            )
            try await research.save(on: app.db)

            let target = Target(
                userId: userId,
                symbol: "AAPL",
                scenario: "base",
                targetPrice: 150,
                targetDate: nil,
                rationale: "12m estimate"
            )
            try await target.save(on: app.db)

            let news = NewsItem(
                userId: userId,
                symbol: "AAPL",
                headline: "Earnings update",
                source: "Reuters",
                url: nil,
                summary: nil,
                publishedAt: Date()
            )
            try await news.save(on: app.db)

            var response: DashboardResponse?
            try await app.testing().test(.GET, "v1/dashboard", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                response = try res.content.decode(DashboardResponse.self)
            })

            #expect(response?.portfolio.totalPositions == 2)
            #expect(response?.portfolio.watchlistCount == 1)
            #expect(response?.portfolio.researchCount == 1)
            #expect(response?.portfolio.targetsCount == 1)
            #expect(response?.portfolio.totalCostBasis == 2_000)
            #expect(response?.portfolio.totalMarketValue == 2_100)
            #expect(response?.portfolio.totalUnrealizedPnl == 100)

            #expect(response?.topHoldings.count == 2)
            #expect(response?.topHoldings.first?.symbol == "AAPL")
            #expect(response?.topHoldings.first?.marketValue == 1_200)

            if let firstWeight = response?.topHoldings.first?.weightPercent {
                #expect(abs(firstWeight - 57.142857) < 0.01)
            } else {
                #expect(Bool(false), "Expected weightPercent for first top holding")
            }

            #expect(response?.recentNews.count == 1)
            #expect(response?.recentNews.first?.symbol == "AAPL")
        }
    }

    @Test("Importing stocks from CSV (commit)")
    func importStocksFromCsvCommit() async throws {
        try await withApp { app in
            let (token, _) = try await registerTestUser(app: app)

            let csv = """
            symbol,shares,buy_price,buy_date,notes
            AAPL,12,145.30,2026-01-10,Long-term core
            """

            var importResponse: CsvImportCommitResponse?
            try await app.testing().test(.POST, "v1/brokers/import/csv/commit?provider=ibkr", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                req.headers.replaceOrAdd(name: .contentType, value: "text/csv")
                req.body = ByteBufferAllocator().buffer(string: csv)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                importResponse = try res.content.decode(CsvImportCommitResponse.self)
            })

            #expect(importResponse?.errors.isEmpty == true)
            #expect(importResponse?.inserted.count == 1)
            #expect(importResponse?.provider == "ibkr")

            try await app.testing().test(.GET, "v1/brokers", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let brokers = try res.content.decode([BrokerConnectionResponse].self)
                let hasIbkrCsv = brokers.contains { broker in
                    broker.provider == "ibkr" && broker.status == "csv"
                }
                #expect(hasIbkrCsv)
            })

            try await app.testing().test(.GET, "v1/stocks", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let stocks = try res.content.decode([StockResponse].self)
                let hasAAPL = stocks.contains { stock in
                    stock.symbol == "AAPL" && stock.shares == 12
                }
                #expect(hasAAPL)
            })
        }
    }
}

actor TestMarketProviderState {
    private var quoteCallCount: Int = 0
    private var historyCallCount: Int = 0
    private var searchCallCount: Int = 0
    private var fxCallCount: Int = 0
    private var failQuoteRequests: Bool = false

    func nextQuoteCall() -> Int {
        quoteCallCount += 1
        return quoteCallCount
    }

    func nextHistoryCall() -> Int {
        historyCallCount += 1
        return historyCallCount
    }

    func nextSearchCall() -> Int {
        searchCallCount += 1
        return searchCallCount
    }

    func nextFxCall() -> Int {
        fxCallCount += 1
        return fxCallCount
    }

    func setFailQuote(_ value: Bool) {
        failQuoteRequests = value
    }

    func shouldFailQuote() -> Bool {
        failQuoteRequests
    }

    func quoteCalls() -> Int {
        quoteCallCount
    }

    func historyCalls() -> Int {
        historyCallCount
    }

    func searchCalls() -> Int {
        searchCallCount
    }

    func fxCalls() -> Int {
        fxCallCount
    }
}

struct TestMarketDataProvider: MarketDataProvider {
    let state: TestMarketProviderState

    var name: String { "ibkr" }

    func quote(symbol: String, on req: Request) async throws -> MarketProviderQuote {
        _ = await state.nextQuoteCall()
        if await state.shouldFailQuote() {
            throw Abort(.badGateway, reason: "Forced quote failure")
        }

        return MarketProviderQuote(
            symbol: symbol,
            price: 101.25,
            currency: "USD",
            asOf: Date()
        )
    }

    func history(symbol: String, from: Date?, to: Date?, on req: Request) async throws -> MarketProviderHistory {
        _ = await state.nextHistoryCall()
        let bar = MarketProviderPriceBar(
            date: Date(),
            open: 100,
            high: 103,
            low: 99,
            close: 101,
            volume: 1_000_000
        )

        return MarketProviderHistory(
            symbol: symbol,
            currency: "USD",
            bars: [bar]
        )
    }

    func search(query: String, on req: Request) async throws -> [MarketProviderSearchResult] {
        _ = await state.nextSearchCall()
        return [
            .init(
                symbol: query,
                name: "\(query) Inc",
                exchange: "NASDAQ",
                currency: "USD",
                conid: "265598"
            )
        ]
    }

    func fx(base: String, quote: String, on req: Request) async throws -> MarketProviderFxRate {
        _ = await state.nextFxCall()
        return .init(base: base, quote: quote, rate: 1.1, asOf: Date())
    }
}
