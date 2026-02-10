@testable import StockPlanBackend
import VaporTesting
import Testing
import Fluent
import NIOCore
import Foundation

@Suite("App Tests with DB", .serialized)
struct StockPlanBackendTests {
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
        let register = AuthRegisterRequest(email: "test@example.com", password: "Password123")
        var response: AuthResponse?

        try await app.testing().test(.POST, "auth/register", beforeRequest: { req in
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
            try await app.testing().test(.GET, "hello", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "Hello, world!")
            })
        }
    }

    @Test("Market quote endpoint requires authentication")
    func quoteRequiresAuth() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(state: state)

            try await app.testing().test(.GET, "quote/AAPL", afterResponse: { res async in
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

            try await app.testing().test(.GET, "quote/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode(QuoteResponse.self)
            })

            try await app.testing().test(.GET, "quote/AAPL", beforeRequest: { req in
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

            try await app.testing().test(.GET, "history/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode(HistoryResponse.self)
            })

            try await app.testing().test(.GET, "history/AAPL", beforeRequest: { req in
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

            try await app.testing().test(.GET, "search?q=AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode([SearchResultResponse].self)
            })

            try await app.testing().test(.GET, "search?q=AAPL", beforeRequest: { req in
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
            try await app.testing().test(.GET, "quote/AAPL", beforeRequest: { req in
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

    @Test("Importing stocks from CSV (commit)")
    func importStocksFromCsvCommit() async throws {
        try await withApp { app in
            let (token, _) = try await registerTestUser(app: app)

            let csv = """
            symbol,shares,buy_price,buy_date,notes
            AAPL,12,145.30,2026-01-10,Long-term core
            """

            var importResponse: CsvImportCommitResponse?
            try await app.testing().test(.POST, "brokers/import/csv/commit?provider=ibkr", beforeRequest: { req in
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

            try await app.testing().test(.GET, "brokers", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let brokers = try res.content.decode([BrokerConnectionResponse].self)
                let hasIbkrCsv = brokers.contains { broker in
                    broker.provider == "ibkr" && broker.status == "csv"
                }
                #expect(hasIbkrCsv)
            })

            try await app.testing().test(.GET, "stocks", beforeRequest: { req in
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
