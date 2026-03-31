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

    private actor TestNewsProviderState {
        private var batches: [[ProviderNewsItem]]
        private var fetchCallCount: Int = 0

        init(batches: [[ProviderNewsItem]]) {
            self.batches = batches
        }

        func next() -> [ProviderNewsItem] {
            fetchCallCount += 1
            guard !batches.isEmpty else { return [] }
            if batches.count == 1 {
                return batches[0]
            }
            return batches.removeFirst()
        }

        func fetchCalls() -> Int {
            fetchCallCount
        }
    }

    private struct TestNewsProvider: NewsProvider {
        let name: String = "test-news"
        let state: TestNewsProviderState

        func fetch(symbols: [String], on req: Request) async throws -> [ProviderNewsItem] {
            await state.next()
        }
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

    private func registerTestUser(
        app: Application,
        identifier: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    ) async throws -> (token: String, userId: UUID) {
        let normalizedIdentifier = String(identifier.prefix(12))
        let register = AuthRegisterRequest(
            username: "test_\(normalizedIdentifier)",
            password: "Password123",
            email: "test+\(normalizedIdentifier)@example.com",
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
        fxTTLSeconds: Int = 3_600,
        profileTTLSeconds: Int = 3_600
    ) -> any MarketDataService {
        DefaultMarketDataService(
            provider: TestMarketDataProvider(state: state),
            cacheConfig: .init(
                quoteTTLSeconds: quoteTTLSeconds,
                historyTTLSeconds: historyTTLSeconds,
                searchTTLSeconds: searchTTLSeconds,
                fxTTLSeconds: fxTTLSeconds,
                profileTTLSeconds: profileTTLSeconds,
                defaultCurrency: "USD"
            )
        )
    }

    private func makeTestMarketNewsArchiveService(
        state: TestNewsProviderState,
        ttlSeconds: Int = 900,
        defaultLimit: Int = 50,
        maxLimit: Int = 200
    ) -> any MarketNewsArchiveService {
        DefaultMarketNewsArchiveService(
            provider: TestNewsProvider(state: state),
            config: .init(
                ttlSeconds: ttlSeconds,
                defaultLimit: defaultLimit,
                maxLimit: maxLimit
            )
        )
    }

    private func makeValuationPayload(
        symbol: String = "AAPL",
        bearLow: Double = 10,
        bearHigh: Double = 15,
        baseLow: Double = 16,
        baseHigh: Double = 22,
        bullLow: Double = 23,
        bullHigh: Double = 30,
        rationale: String? = nil,
        targetDate: String? = "2026-12-31"
    ) -> StockValuationRequest {
        StockValuationRequest(
            symbol: symbol,
            bearCase: PriceRange(low: bearLow, high: bearHigh),
            baseCase: PriceRange(low: baseLow, high: baseHigh),
            bullCase: PriceRange(low: bullLow, high: bullHigh),
            rationale: rationale,
            targetDate: targetDate
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

    @Test("Stock valuation endpoints create, fetch, and update by symbol")
    func stockValuationLifecycle() async throws {
        try await withApp { app in
            let (token, _) = try await registerTestUser(app: app)

            try await app.testing().test(.POST, "v1/stocks", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    StockRequest(
                        symbol: "AAPL",
                        shares: 2,
                        buyPrice: 100,
                        buyDate: "2024-01-01",
                        notes: nil
                    )
                )
            }, afterResponse: { res async in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/stocks/symbol/AAPL/valuation", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    makeValuationPayload(symbol: "AAPL", rationale: "original thesis")
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                let body = try res.content.decode(StockValuationRequest.self)
                #expect(body.symbol == "AAPL")
                #expect(body.bearCase.low == 10)
            })

            try await app.testing().test(.GET, "v1/stocks/symbol/aapl/valuation", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(StockValuationRequest.self)
                #expect(body.baseCase.high == 22)
                #expect(body.rationale == "original thesis")
            })

            try await app.testing().test(.PUT, "v1/stocks/symbol/AAPL/valuation", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    makeValuationPayload(symbol: "AAPL", baseHigh: 29, bullHigh: 36)
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(StockValuationRequest.self)
                #expect(body.baseCase.high == 29)
                #expect(body.bullCase.high == 36)
            })
        }
    }

    @Test("Stock valuation endpoints are scoped to the authenticated user")
    func stockValuationIsUserScoped() async throws {
        try await withApp { app in
            let (ownerToken, _) = try await registerTestUser(app: app, identifier: "owner")
            let (otherToken, _) = try await registerTestUser(app: app, identifier: "other")

            try await app.testing().test(.POST, "v1/stocks", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerToken)
                try req.content.encode(
                    StockRequest(
                        symbol: "ZETA",
                        shares: 5,
                        buyPrice: 15,
                        buyDate: "2024-01-01",
                        notes: nil
                    )
                )
            }, afterResponse: { res async in
                #expect(res.status == .created)
            })

            try await app.testing().test(.POST, "v1/stocks/symbol/ZETA/valuation", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: ownerToken)
                try req.content.encode(
                    makeValuationPayload(symbol: "ZETA", rationale: "owner thesis")
                )
            }, afterResponse: { res async in
                #expect(res.status == .created)
            })

            try await app.testing().test(.GET, "v1/stocks/symbol/ZETA/valuation", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: otherToken)
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })

            try await app.testing().test(.POST, "v1/stocks/symbol/ZETA/valuation", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: otherToken)
                try req.content.encode(
                    makeValuationPayload(symbol: "ZETA", rationale: "other thesis")
                )
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
                #expect(res.body.string.contains("Stock not found."))
            })
        }
    }

    @Test("Watchlist endpoints create, update, and list enriched items")
    func watchlistLifecycle() async throws {
        try await withApp { app in
            let (token, _) = try await registerTestUser(app: app)

            var created: WatchlistItemResponse?
            try await app.testing().test(.POST, "v1/watchlist", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    WatchlistItemRequest(
                        symbol: "msft",
                        note: "Waiting for a better entry",
                        status: .researching,
                        nextReviewAt: "2026-04-15"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .created)
                created = try res.content.decode(WatchlistItemResponse.self)
            })

            #expect(created?.symbol == "MSFT")
            #expect(created?.note == "Waiting for a better entry")
            #expect(created?.status == .researching)
            #expect(created?.nextReviewAt == "2026-04-15")
            #expect(created?.createdAt != nil)

            let watchlistId = try #require(created?.id)

            try await app.testing().test(.PATCH, "v1/watchlist/\(watchlistId)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
                try req.content.encode(
                    WatchlistItemUpdateRequest(
                        note: "",
                        status: .ready,
                        lastReviewedAt: "2026-03-20",
                        nextReviewAt: "2026-05-01"
                    )
                )
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let updated = try res.content.decode(WatchlistItemResponse.self)
                #expect(updated.id == watchlistId)
                #expect(updated.note == nil)
                #expect(updated.status == .ready)
                #expect(updated.lastReviewedAt == "2026-03-20")
                #expect(updated.nextReviewAt == "2026-05-01")
                #expect(updated.updatedAt != nil)
            })

            try await app.testing().test(.GET, "v1/watchlist", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let items = try res.content.decode([WatchlistItemResponse].self)
                #expect(items.count == 1)
                #expect(items.first?.id == watchlistId)
                #expect(items.first?.status == .ready)
                #expect(items.first?.note == nil)
                #expect(items.first?.lastReviewedAt == "2026-03-20")
            })
        }
    }

    @Test("Market compatibility endpoints return stock details, history, and news")
    func marketCompatibilityEndpoints() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(state: state)
            let (token, _) = try await registerTestUser(app: app)

            let news = MarketNewsArchive(
                provider: "test-news",
                symbol: "ZETA",
                headline: "ZETA wins new contract",
                source: "Example Wire",
                url: "https://example.com/zeta",
                summary: "Summary",
                publishedAt: Date(),
                fetchedAt: Date()
            )
            try await news.save(on: app.db)

            try await app.testing().test(.GET, "v1/market/details?symbol=ZETA", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(StockDetailsResponse.self)
                #expect(body.symbol == "ZETA")
                #expect(body.company == "ZETA Inc")
                #expect(body.latestPrice == 101.25)
                #expect(body.changePercent > 0)
            })

            try await app.testing().test(.GET, "v1/market/history?symbol=ZETA", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockHistory].self)
                #expect(body.count == 1)
                #expect(body.first?.close == 101)
            })

            try await app.testing().test(.GET, "v1/market/news?symbol=ZETA", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockNews].self)
                #expect(body.count == 1)
                #expect(body.first?.title == "ZETA wins new contract")
                #expect(body.first?.url == "https://example.com/zeta")
            })
        }
    }

    @Test("Archived market history endpoints read stored bars and sync provider data into the archive")
    func archivedMarketHistoryEndpoints() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(state: state)
            let (token, _) = try await registerTestUser(app: app, identifier: "historyarchive")

            let seededDay = Calendar(identifier: .gregorian).startOfDay(for: Date().addingTimeInterval(-86_400))
            try await PriceHistory(
                symbol: "AAPL",
                date: seededDay,
                open: 90,
                high: 95,
                low: 88,
                close: 94,
                volume: 750_000
            ).save(on: app.db)

            try await app.testing().test(.GET, "v1/market/history/archive?symbol=AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockHistory].self)
                #expect(body.count == 1)
                #expect(body.first?.close == 94)
            })

            try await app.testing().test(.POST, "v1/market/history/archive/sync?symbol=AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockHistory].self)
                #expect(body.count >= 1)
                #expect(body.first?.close == 101)
            })

            try await app.testing().test(.GET, "v1/market/history/archive?symbol=AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockHistory].self)
                #expect(body.contains(where: { $0.close == 101 }))
            })

            #expect(await state.historyCalls() == 1)
        }
    }

    @Test("Archived market news is shared across users and compatibility reads come from the DB archive")
    func archivedMarketNewsSharedAcrossUsers() async throws {
        try await withApp { app in
            let state = TestNewsProviderState(batches: [[
                ProviderNewsItem(
                    symbol: "AAPL",
                    headline: "Apple launches archived news",
                    source: "Example Wire",
                    url: "https://example.com/news/apple-archive",
                    summary: "Archived market news",
                    publishedAt: Date(timeIntervalSince1970: 1_774_884_000)
                )
            ]])
            app.marketNewsArchiveService = makeTestMarketNewsArchiveService(state: state)

            let (token1, _) = try await registerTestUser(app: app, identifier: "archiveuser1")
            let (token2, _) = try await registerTestUser(app: app, identifier: "archiveuser2")

            try await app.testing().test(.POST, "v1/market/news/archive/sync?symbol=AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token1)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockNews].self)
                #expect(body.count == 1)
                #expect(body.first?.title == "Apple launches archived news")
            })

            try await app.testing().test(.GET, "v1/market/news/archive?symbol=AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token2)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockNews].self)
                #expect(body.count == 1)
                #expect(body.first?.url == "https://example.com/news/apple-archive")
            })

            try await app.testing().test(.GET, "v1/market/news?symbol=AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token2)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockNews].self)
                #expect(body.count == 1)
                #expect(body.first?.title == "Apple launches archived news")
            })

            #expect(await state.fetchCalls() == 1)
        }
    }

    @Test("Market compatibility endpoints degrade gracefully when provider is disabled")
    func marketCompatibilityEndpointsWhenProviderDisabled() async throws {
        try await withApp { app in
            app.marketDataService = DefaultMarketDataService(
                provider: DisabledMarketDataProvider(),
                cacheConfig: .init(
                    quoteTTLSeconds: 3_600,
                    historyTTLSeconds: 3_600,
                    searchTTLSeconds: 3_600,
                    fxTTLSeconds: 3_600,
                    profileTTLSeconds: 3_600,
                    defaultCurrency: "USD"
                )
            )
            let (token, _) = try await registerTestUser(app: app, identifier: "marketdisabled")

            try await app.testing().test(.GET, "v1/market/details?symbol=ZETA", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(StockDetailsResponse.self)
                #expect(body.symbol == "ZETA")
                #expect(body.company == "ZETA")
                #expect(body.latestPrice == 0)
                #expect(body.changePercent == 0)
            })

            try await app.testing().test(.GET, "v1/market/history?symbol=ZETA", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockHistory].self)
                #expect(body.isEmpty)
            })
        }
    }

    @Test("Market history returns a diagnosable 503 when the provider is unavailable")
    func marketHistoryProviderUnavailable() async throws {
        try await withApp { app in
            app.marketDataService = DefaultMarketDataService(
                provider: FailingMarketDataProvider(),
                cacheConfig: .init(
                    quoteTTLSeconds: 3_600,
                    historyTTLSeconds: 3_600,
                    searchTTLSeconds: 3_600,
                    fxTTLSeconds: 3_600,
                    profileTTLSeconds: 3_600,
                    defaultCurrency: "USD"
                )
            )

            let (token, _) = try await registerTestUser(app: app, identifier: "market503")

            try await app.testing().test(.GET, "v1/market/history?symbol=ZETA", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async in
                #expect(res.status == .badGateway)
                #expect(res.body.string.contains("Forced market provider failure"))
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
            #expect(first?.c == second?.c)
            #expect(await state.quoteCalls() == 1)
        }
    }

    @Test("Profile uses cache after first fetch")
    func profileUsesCache() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(state: state)
            let (token, _) = try await registerTestUser(app: app)

            var first: CompanyProfileResponse?
            var second: CompanyProfileResponse?

            try await app.testing().test(.GET, "v1/profile/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode(CompanyProfileResponse.self)
            })

            try await app.testing().test(.GET, "v1/profile/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                second = try res.content.decode(CompanyProfileResponse.self)
            })

            #expect(first?.ticker == "AAPL")
            #expect(second?.ticker == "AAPL")
            #expect(first?.name == second?.name)
            #expect(await state.profileCalls() == 1)
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
            #expect(response?.c == 123.45)
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

    @Test("Finnhub news webhook ingests tracked symbols and deduplicates repeated deliveries")
    func finnhubNewsWebhookIngestsTrackedSymbols() async throws {
        setenv("FINNHUB_WEBHOOK_SECRET", "test-finnhub-secret", 1)
        setenv("FINNHUB_WEBHOOK_URL", "http://localhost:8080/webhooks/finnhub/news", 1)
        defer {
            unsetenv("FINNHUB_WEBHOOK_SECRET")
            unsetenv("FINNHUB_WEBHOOK_URL")
        }

        try await withApp { app in
            let (_, user1Id) = try await registerTestUser(app: app, identifier: "finnhubnews1")
            let (_, user2Id) = try await registerTestUser(app: app, identifier: "finnhubnews2")

            try await Stock(
                userId: user1Id,
                symbol: "AAPL",
                shares: 5,
                buyPrice: 100,
                buyDate: Date()
            ).save(on: app.db)
            try await WatchlistItem(userId: user1Id, symbol: "MSFT").save(on: app.db)
            try await WatchlistItem(userId: user2Id, symbol: "AAPL").save(on: app.db)

            let payload = FinnhubNewsWebhookRequest(news: [
                FinnhubNewsWebhookItem(
                    category: "company",
                    datetime: 1_774_884_000,
                    headline: "Apple launches a new enterprise service",
                    id: 42,
                    image: nil,
                    related: "AAPL,MSFT,TSLA",
                    source: "Reuters",
                    summary: "Sample webhook article",
                    symbol: nil,
                    symbols: nil,
                    publishedAt: nil,
                    url: "https://example.com/news/apple-enterprise-service"
                )
            ])

            var firstResponse: FinnhubNewsWebhookResponse?
            var secondResponse: FinnhubNewsWebhookResponse?

            try await app.testing().test(.POST, "webhooks/finnhub/news", beforeRequest: { req in
                req.headers.add(name: "X-Finnhub-Secret", value: "test-finnhub-secret")
                try req.content.encode(payload)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                firstResponse = try res.content.decode(FinnhubNewsWebhookResponse.self)
            })

            try await app.testing().test(.POST, "webhooks/finnhub/news", beforeRequest: { req in
                req.headers.add(name: "X-Finnhub-Secret", value: "test-finnhub-secret")
                try req.content.encode(payload)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                secondResponse = try res.content.decode(FinnhubNewsWebhookResponse.self)
            })

            #expect(firstResponse?.provider == "finnhub")
            #expect(firstResponse?.receivedCount == 1)
            #expect(firstResponse?.matchedSymbolsCount == 2)
            #expect(firstResponse?.matchedUsersCount == 2)
            #expect(firstResponse?.insertedCount == 3)
            #expect(firstResponse?.skippedCount == 0)

            #expect(secondResponse?.insertedCount == 0)
            #expect(secondResponse?.skippedCount == 3)

            let user1News = try await NewsItem.query(on: app.db)
                .filter(\.$userId == user1Id)
                .sort(\.$symbol, .ascending)
                .all()
            let user2News = try await NewsItem.query(on: app.db)
                .filter(\.$userId == user2Id)
                .all()

            #expect(user1News.count == 2)
            #expect(user2News.count == 1)
            #expect(user1News.map(\.symbol) == ["AAPL", "MSFT"])
            #expect(user2News.first?.symbol == "AAPL")
        }
    }

    @Test("Finnhub news webhook rejects an invalid secret")
    func finnhubNewsWebhookRejectsInvalidSecret() async throws {
        setenv("FINNHUB_WEBHOOK_SECRET", "test-finnhub-secret", 1)
        defer { unsetenv("FINNHUB_WEBHOOK_SECRET") }

        try await withApp { app in
            let payload = FinnhubNewsWebhookRequest(news: [
                FinnhubNewsWebhookItem(
                    category: "company",
                    datetime: 1_774_884_000,
                    headline: "Invalid secret test",
                    id: 99,
                    image: nil,
                    related: "AAPL",
                    source: "Reuters",
                    summary: nil,
                    symbol: nil,
                    symbols: nil,
                    publishedAt: nil,
                    url: "https://example.com/news/invalid-secret"
                )
            ])

            try await app.testing().test(.POST, "webhooks/finnhub/news", beforeRequest: { req in
                req.headers.add(name: "X-Finnhub-Secret", value: "wrong-secret")
                try req.content.encode(payload)
            }, afterResponse: { res async in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("News sync persists provider items, filters untracked symbols, and updates duplicates")
    func newsSyncPersistsProviderItems() async throws {
        try await withApp { app in
            let (token, userId) = try await registerTestUser(app: app, identifier: "newssync")

            try await Stock(
                userId: userId,
                symbol: "AAPL",
                shares: 5,
                buyPrice: 100,
                buyDate: Date()
            ).save(on: app.db)
            try await WatchlistItem(userId: userId, symbol: "MSFT").save(on: app.db)

            let publishedAt = Date(timeIntervalSince1970: 1_774_884_000)
            let providerState = TestNewsProviderState(batches: [
                [
                    ProviderNewsItem(
                        symbol: "AAPL",
                        headline: "Apple launches a new enterprise service",
                        source: "Reuters",
                        url: "https://example.com/news/apple-enterprise-service",
                        summary: "Initial summary",
                        publishedAt: publishedAt
                    ),
                    ProviderNewsItem(
                        symbol: "TSLA",
                        headline: "Tesla opens a new plant",
                        source: "Reuters",
                        url: "https://example.com/news/tesla-new-plant",
                        summary: "Untracked symbol should be skipped",
                        publishedAt: publishedAt
                    )
                ],
                [
                    ProviderNewsItem(
                        symbol: "AAPL",
                        headline: "Apple launches a new enterprise service",
                        source: "Reuters",
                        url: "https://example.com/news/apple-enterprise-service",
                        summary: "Updated summary",
                        publishedAt: publishedAt.addingTimeInterval(5)
                    ),
                    ProviderNewsItem(
                        symbol: "TSLA",
                        headline: "Tesla opens a new plant",
                        source: "Reuters",
                        url: "https://example.com/news/tesla-new-plant",
                        summary: "Untracked symbol should still be skipped",
                        publishedAt: publishedAt
                    )
                ]
            ])
            app.newsService = DefaultNewsService(
                repo: app.newsRepository,
                provider: TestNewsProvider(state: providerState)
            )

            var firstResponse: NewsSyncResponse?
            var secondResponse: NewsSyncResponse?

            try await app.testing().test(.POST, "v1/news/sync", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                firstResponse = try res.content.decode(NewsSyncResponse.self)
            })

            try await app.testing().test(.POST, "v1/news/sync", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                secondResponse = try res.content.decode(NewsSyncResponse.self)
            })

            #expect(firstResponse?.provider == "test-news")
            #expect(firstResponse?.symbolsCount == 2)
            #expect(firstResponse?.fetchedCount == 2)
            #expect(firstResponse?.insertedCount == 1)
            #expect(firstResponse?.updatedCount == 0)
            #expect(firstResponse?.skippedCount == 1)

            #expect(secondResponse?.provider == "test-news")
            #expect(secondResponse?.symbolsCount == 2)
            #expect(secondResponse?.fetchedCount == 2)
            #expect(secondResponse?.insertedCount == 0)
            #expect(secondResponse?.updatedCount == 1)
            #expect(secondResponse?.skippedCount == 1)

            let items = try await NewsItem.query(on: app.db)
                .filter(\.$userId == userId)
                .all()

            #expect(items.count == 1)
            #expect(items.first?.symbol == "AAPL")
            #expect(items.first?.summary == "Updated summary")
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
    private var profileCallCount: Int = 0
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

    func nextProfileCall() -> Int {
        profileCallCount += 1
        return profileCallCount
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

    func profileCalls() -> Int {
        profileCallCount
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
            change: nil,
            percentChange: nil,
            high: nil,
            low: nil,
            open: nil,
            previousClose: nil,
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

    func profile(symbol: String, on req: Request) async throws -> MarketProviderCompanyProfile? {
        _ = await state.nextProfileCall()
        return MarketProviderCompanyProfile(
            symbol: symbol,
            country: "US",
            currency: "USD",
            estimateCurrency: "USD",
            exchange: "NASDAQ",
            finnhubIndustry: "Technology",
            ipo: "1980-12-12",
            logo: "https://example.com/logo.png",
            marketCapitalization: 1000.0,
            name: "Apple Inc",
            phone: "123456789",
            shareOutstanding: 100.0,
            ticker: symbol,
            weburl: "https://apple.com"
        )
    }
}

struct FailingMarketDataProvider: MarketDataProvider {
    var name: String { "ibkr" }

    func quote(symbol: String, on req: Request) async throws -> MarketProviderQuote {
        throw Abort(.badGateway, reason: "Forced market provider failure")
    }

    func history(symbol: String, from: Date?, to: Date?, on req: Request) async throws
        -> MarketProviderHistory
    {
        throw Abort(.badGateway, reason: "Forced market provider failure")
    }

    func search(query: String, on req: Request) async throws -> [MarketProviderSearchResult] {
        throw Abort(.badGateway, reason: "Forced market provider failure")
    }

    func fx(base: String, quote: String, on req: Request) async throws -> MarketProviderFxRate {
        throw Abort(.badGateway, reason: "Forced market provider failure")
    }

    func profile(symbol: String, on req: Request) async throws -> MarketProviderCompanyProfile? {
        throw Abort(.badGateway, reason: "Forced market provider failure")
    }
}
