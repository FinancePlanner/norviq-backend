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

        func fetchGeneral(on req: Request) async throws -> [ProviderNewsItem] {
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
        fmpState: TestFMPProviderState? = nil,
        fmpProvider: (any FMPMarketDataProvider)? = nil,
        fmpAccessTier: FMPAccessTier = .free,
        quoteTTLSeconds: Int = 3_600,
        historyTTLSeconds: Int = 3_600,
        searchTTLSeconds: Int = 3_600,
        fxTTLSeconds: Int = 3_600,
        profileTTLSeconds: Int = 3_600,
        basicFinancialsTTLSeconds: Int = 3_600
    ) -> any MarketDataService {
        DefaultMarketDataService(
            provider: TestMarketDataProvider(state: state),
            fmpProvider: fmpProvider ?? fmpState.map { TestFMPMarketDataProvider(state: $0) },
            cacheConfig: .init(
                quoteTTLSeconds: quoteTTLSeconds,
                historyTTLSeconds: historyTTLSeconds,
                searchTTLSeconds: searchTTLSeconds,
                fxTTLSeconds: fxTTLSeconds,
                profileTTLSeconds: profileTTLSeconds,
                basicFinancialsTTLSeconds: basicFinancialsTTLSeconds,
                fmpTTLSeconds: 3_600,
                defaultCurrency: "USD"
            ),
            fmpAccessTier: fmpAccessTier
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
                imageURL: nil,
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
                    image: nil,
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
                    basicFinancialsTTLSeconds: 3_600,
                    fmpTTLSeconds: 3_600,
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
                    basicFinancialsTTLSeconds: 3_600,
                    fmpTTLSeconds: 3_600,
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

            try await app.testing().test(.GET, "v1/market/quote/AAPL", afterResponse: { res async in
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

            try await app.testing().test(.GET, "v1/market/quote/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode(QuoteResponse.self)
            })

            try await app.testing().test(.GET, "v1/market/quote/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                second = try res.content.decode(QuoteResponse.self)
            })

            #expect(first?.symbol == "AAPL")
            #expect(second?.symbol == "AAPL")
            #expect(first?.currentPrice == second?.currentPrice)
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

            try await app.testing().test(.GET, "v1/market/profile/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode(CompanyProfileResponse.self)
            })

            try await app.testing().test(.GET, "v1/market/profile/AAPL", beforeRequest: { req in
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

    @Test("Basic financials use cache after first fetch")
    func basicFinancialsUseCache() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(state: state)
            let (token, _) = try await registerTestUser(app: app, identifier: "basicfinancials")

            var first: BasicFinancialsResponse?
            var second: BasicFinancialsResponse?

            try await app.testing().test(.GET, "v1/market/basic-financials/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode(BasicFinancialsResponse.self)
            })

            try await app.testing().test(.GET, "v1/market/basic-financials/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                second = try res.content.decode(BasicFinancialsResponse.self)
            })

            #expect(first?.symbol == "AAPL")
            #expect(first?.metricType == "all")
            #expect(first?.metric["52WeekHigh"] == .number(190.25))
            #expect(first?.metric["52WeekLowDate"] == .string("2026-01-14"))
            #expect(first?.series["annual"]?["currentRatio"]?.count == 2)
            #expect(second?.metric["beta"] == .number(1.2989))
            #expect(first == second)
            #expect(await state.basicFinancialsCalls() == 1)
        }
    }

    @Test("Ratios TTM endpoint returns FMP-backed market data")
    func ratiosTTMEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, _) = try await registerTestUser(app: app, identifier: "ratiosttm")

            try await app.testing().test(.GET, "v1/market/ratios-ttm/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([RatiosTTMResponse].self)
                #expect(body.count == 1)
                #expect(body.first?.symbol == "AAPL")
                #expect(body.first?.grossProfitMarginTTM == 0.46518849807964424)
                #expect(body.first?.enterpriseValueTTM == 3_216_333_928_000)
            })

            #expect(await fmpState.ratiosTTMCalls() == 1)
        }
    }

    @Test("Balance sheet statement endpoint forwards limit and period to FMP")
    func balanceSheetStatementEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, _) = try await registerTestUser(app: app, identifier: "balancesheet")

            try await app.testing().test(.GET, "v1/market/balance-sheet-statement/AAPL?limit=5&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([BalanceSheetStatementResponse].self)
                #expect(body.count == 1)
                #expect(body.first?.symbol == "AAPL")
                #expect(body.first?.period == "FY")
                #expect(body.first?.totalAssets == 364_980_000_000)
                #expect(body.first?.totalLiabilities == 308_030_000_000)
                #expect(body.first?.totalStockholdersEquity == 56_950_000_000)
            })

            let lastRequest = await fmpState.lastBalanceSheetRequest()
            #expect(lastRequest?.symbol == "AAPL")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.period == "FY")
        }
    }

    @Test("Balance sheet statement endpoint clamps free-tier limit to plan-safe maximum")
    func balanceSheetStatementEndpointClampsFreeTierLimit() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, _) = try await registerTestUser(app: app, identifier: "balancesheetclamp")

            try await app.testing().test(.GET, "v1/market/balance-sheet-statement/META?limit=10&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let lastRequest = await fmpState.lastBalanceSheetRequest()
            #expect(lastRequest?.symbol == "META")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.period == "FY")
        }
    }

    @Test("Cash flow statement endpoint forwards limit and period to FMP")
    func cashFlowStatementEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, _) = try await registerTestUser(app: app, identifier: "cashflow")

            try await app.testing().test(.GET, "v1/market/cash-flow-statement/AAPL?limit=5&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([CashFlowStatementResponse].self)
                #expect(body.count == 1)
                #expect(body.first?.symbol == "AAPL")
                #expect(body.first?.period == "FY")
                #expect(body.first?.operatingCashFlow == 118_254_000_000)
                #expect(body.first?.freeCashFlow == 108_807_000_000)
                #expect(body.first?.capitalExpenditure == -9_447_000_000)
            })

            let lastRequest = await fmpState.lastCashFlowRequest()
            #expect(lastRequest?.symbol == "AAPL")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.period == "FY")
        }
    }

    @Test("Cash flow statement endpoint clamps free-tier limit to plan-safe maximum")
    func cashFlowStatementEndpointClampsFreeTierLimit() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, _) = try await registerTestUser(app: app, identifier: "cashflowclamp")

            try await app.testing().test(.GET, "v1/market/cash-flow-statement/META?limit=10&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let lastRequest = await fmpState.lastCashFlowRequest()
            #expect(lastRequest?.symbol == "META")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.period == "FY")
        }
    }

    @Test("Compare endpoint returns metrics for multiple symbols")
    func compareEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, _) = try await registerTestUser(app: app, identifier: "comparemetrics")

            try await app.testing().test(.GET, "v1/market/compare?symbols=AAPL,MSFT", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([StockAnalysisMetricsResponse].self)
                #expect(body.count == 2)
                let symbols = body.map(\.symbol)
                #expect(symbols.contains("AAPL"))
                #expect(symbols.contains("MSFT"))
                
                if let aapl = body.first(where: { $0.symbol == "AAPL" }) {
                    #expect(aapl.ttmPE == 32.889608822880916)
                    #expect(aapl.forwardPE == 28.0)
                }
            })

            #expect(await state.basicFinancialsCalls() == 2)
            #expect(await fmpState.ratiosTTMCalls() == 2)
        }
    }

    @Test("Earnings endpoint returns data for supported symbols")
    func earningsEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, _) = try await registerTestUser(app: app, identifier: "earningsuser")

            try await app.testing().test(.GET, "v1/market/earnings/AAPL?limit=10", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([EarningsResponse].self)
                #expect(body.count == 1)
                #expect(body.first?.symbol == "AAPL")
                #expect(body.first?.epsActual == 1.64)
            })

            #expect(await fmpState.earningsCalls() == 1)
        }
    }

    @Test("Earnings calendar endpoint validates date range by tier")
    func earningsCalendarEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            // Default is free tier
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, _) = try await registerTestUser(app: app, identifier: "calendaruser")

            // Test free tier limit (1 month) - 2 months ago should fail
            let twoMonthsAgo = Calendar.current.date(byAdding: .month, value: -2, to: Date())!
            let from = formatISODateOnly(twoMonthsAgo)

            try await app.testing().test(.GET, "v1/market/earnings-calendar?from=\(from)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                #expect(res.body.string.contains("limited to 1 month"))
            })

            // Test free tier within range
            let twoWeeksAgo = Calendar.current.date(byAdding: .day, value: -14, to: Date())!
            let fromOk = formatISODateOnly(twoWeeksAgo)

            try await app.testing().test(.GET, "v1/market/earnings-calendar?from=\(fromOk)", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([EarningsResponse].self)
                #expect(body.count == 1)
            })

            #expect(await fmpState.earningsCalendarCalls() == 1)
        }
    }

    @Test("Analysis endpoint returns server-computed metrics for the analysis tab")
    func analysisEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, _) = try await registerTestUser(app: app, identifier: "analysismetrics")

            try await app.testing().test(.GET, "v1/market/analysis/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(StockAnalysisMetricsResponse.self)
                #expect(body.symbol == "AAPL")
                #expect(body.ttmPE == 32.889608822880916)
                #expect(body.forwardPE == 28.0)
                #expect(body.ttmEPSGrowth == 0.12)
                #expect(body.currentYearExpectedRevenueGrowth == 0.020219940775141214)
                #expect(body.nextYearRevenueGrowth == 0.031)
                #expect(body.grossMargin == 0.46518849807964424)
                #expect(body.netMargin == 0.24295027289266222)
                #expect(body.currentQuarterRevenueGrowthVsPreviousYear == 0.07)
            })

            #expect(await state.basicFinancialsCalls() == 1)
            #expect(await fmpState.ratiosTTMCalls() == 1)
            let lastGrowthRequest = await fmpState.lastFinancialGrowthRequest()
            #expect(lastGrowthRequest?.symbol == "AAPL")
            #expect(lastGrowthRequest?.limit == 5)
            #expect(lastGrowthRequest?.period == "FY")
        }
    }

    @Test("Ratios TTM endpoint returns 402 for symbols outside free-tier FMP coverage")
    func ratiosTTMEndpointReturnsPaymentRequiredForUnsupportedFreeTierSymbol() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, _) = try await registerTestUser(app: app, identifier: "ratiosplanlimit")

            try await app.testing().test(.GET, "v1/market/ratios-ttm/ZETA", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                #expect(res.body.string.contains("FMP free-tier coverage for ratios-ttm"))
            })

            #expect(await fmpState.ratiosTTMCalls() == 0)
        }
    }

    @Test("Balance sheet statement endpoint returns 402 for symbols outside free-tier FMP coverage")
    func balanceSheetStatementEndpointReturnsPaymentRequiredForUnsupportedFreeTierSymbol() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, _) = try await registerTestUser(app: app, identifier: "balanceplanlimit")

            try await app.testing().test(.GET, "v1/market/balance-sheet-statement/ZETA?limit=5&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                #expect(res.body.string.contains("FMP free-tier coverage for balance-sheet-statement"))
            })

            #expect(await fmpState.lastBalanceSheetRequest() == nil)
        }
    }

    @Test("Cash flow statement endpoint returns 402 for symbols outside free-tier FMP coverage")
    func cashFlowStatementEndpointReturnsPaymentRequiredForUnsupportedFreeTierSymbol() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, _) = try await registerTestUser(app: app, identifier: "cashflowplanlimit")

            try await app.testing().test(.GET, "v1/market/cash-flow-statement/ZETA?limit=5&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                #expect(res.body.string.contains("FMP free-tier coverage for cash-flow-statement"))
            })

            #expect(await fmpState.lastCashFlowRequest() == nil)
        }
    }

    @Test("Grades consensus endpoint returns FMP-backed analyst consensus data")
    func gradesConsensusEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, _) = try await registerTestUser(app: app, identifier: "gradesconsensus")

            try await app.testing().test(.GET, "v1/market/grades-consensus/UBER", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([GradesConsensusResponse].self)
                #expect(body.count == 1)
                #expect(body.first?.symbol == "UBER")
                #expect(body.first?.strongBuy == 1)
                #expect(body.first?.buy == 49)
                #expect(body.first?.hold == 11)
                #expect(body.first?.sell == 0)
                #expect(body.first?.strongSell == 0)
                #expect(body.first?.consensus == "Buy")
            })

            #expect(await fmpState.gradesConsensusCalls() == 1)
        }
    }

    @Test("Grades consensus endpoint returns 402 when the symbol requires a paid FMP plan")
    func gradesConsensusEndpointReturnsPaymentRequiredForPlanLimitedSymbol() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            app.marketDataService = makeTestMarketService(
                state: state,
                fmpProvider: TestPaymentRequiredFMPMarketDataProvider()
            )
            let (token, _) = try await registerTestUser(app: app, identifier: "gradespremium")

            try await app.testing().test(.GET, "v1/market/grades-consensus/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                let body = res.body.string
                #expect(body.contains("FMP plan upgrade required"))
                #expect(body.contains("grades-consensus"))
            })
        }
    }

    @Test("Financial growth endpoint forwards limit and period to FMP")
    func financialGrowthEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, _) = try await registerTestUser(app: app, identifier: "financialgrowth")

            try await app.testing().test(.GET, "v1/market/financial-growth/AAPL?limit=5&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([FinancialGrowthResponse].self)
                #expect(body.count == 2)
                #expect(body.first?.symbol == "AAPL")
                #expect(body.first?.period == "FY")
                #expect(body.first?.revenueGrowth == 0.020219940775141214)
            })

            let lastRequest = await fmpState.lastFinancialGrowthRequest()
            #expect(lastRequest?.symbol == "AAPL")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.period == "FY")
        }
    }

    @Test("Financial growth endpoint clamps free-tier limit to plan-safe maximum")
    func financialGrowthEndpointClampsFreeTierLimit() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, _) = try await registerTestUser(app: app, identifier: "financialgrowthclamp")

            try await app.testing().test(.GET, "v1/market/financial-growth/META?limit=10&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let lastRequest = await fmpState.lastFinancialGrowthRequest()
            #expect(lastRequest?.symbol == "META")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.period == "FY")
        }
    }

    @Test("Financial growth endpoint returns 402 for symbols outside free-tier FMP coverage")
    func financialGrowthEndpointReturnsPaymentRequiredForUnsupportedFreeTierSymbol() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, _) = try await registerTestUser(app: app, identifier: "growthplanlimit")

            try await app.testing().test(.GET, "v1/market/financial-growth/ZETA?limit=5&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                #expect(res.body.string.contains("FMP free-tier coverage for financial-growth"))
            })

            #expect(await fmpState.lastFinancialGrowthRequest() == nil)
        }
    }

    @Test("Analyst estimates endpoint forwards parameters to FMP")
    func analystEstimatesEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, _) = try await registerTestUser(app: app, identifier: "analystestimates")

            try await app.testing().test(.GET, "v1/market/analyst-estimates/AAPL?period=annual&limit=5&page=0", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([AnalystEstimatesResponse].self)
                #expect(body.count == 1)
                #expect(body.first?.symbol == "AAPL")
                #expect(body.first?.epsAvg == 9.68)
            })

            let lastRequest = await fmpState.lastAnalystEstimatesRequest()
            #expect(lastRequest?.symbol == "AAPL")
            #expect(lastRequest?.period == "annual")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.page == 0)
        }
    }

    @Test("Analyst estimates endpoint clamps free-tier limit to plan-safe maximum")
    func analystEstimatesEndpointClampsFreeTierLimit() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, _) = try await registerTestUser(app: app, identifier: "analystestimatesclamp")

            try await app.testing().test(.GET, "v1/market/analyst-estimates/META?period=annual&limit=10&page=0", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let lastRequest = await fmpState.lastAnalystEstimatesRequest()
            #expect(lastRequest?.symbol == "META")
            #expect(lastRequest?.period == "annual")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.page == 0)
        }
    }

    @Test("Analyst estimates endpoint returns 402 for non-annual period on free-tier")
    func analystEstimatesEndpointReturnsPaymentRequiredForNonAnnualPeriodOnFreeTier() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, _) = try await registerTestUser(app: app, identifier: "estimatesperiodlimit")

            try await app.testing().test(.GET, "v1/market/analyst-estimates/AAPL?period=quarter", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                #expect(res.body.string.contains("FMP free-tier for analyst-estimates is limited to annual reports"))
            })

            #expect(await fmpState.lastAnalystEstimatesRequest() == nil)
        }
    }

    @Test("Analyst estimates endpoint returns 402 for symbols outside free-tier FMP coverage")
    func analystEstimatesEndpointReturnsPaymentRequiredForUnsupportedFreeTierSymbol() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, _) = try await registerTestUser(app: app, identifier: "estimatesplanlimit")

            try await app.testing().test(.GET, "v1/market/analyst-estimates/ZETA", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                #expect(res.body.string.contains("FMP free-tier coverage for analyst-estimates"))
            })

            #expect(await fmpState.lastAnalystEstimatesRequest() == nil)
        }
    }

    @Test("Ratios endpoint forwards limit and period to FMP")
    func ratiosEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, _) = try await registerTestUser(app: app, identifier: "ratios")

            try await app.testing().test(.GET, "v1/market/ratios/AAPL?limit=5&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode([RatiosResponse].self)
                #expect(body.count == 1)
                #expect(body.first?.symbol == "AAPL")
                #expect(body.first?.grossProfitMargin == 0.4620634981523393)
            })

            let lastRequest = await fmpState.lastRatiosRequest()
            #expect(lastRequest?.symbol == "AAPL")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.period == "FY")
        }
    }

    @Test("Ratios endpoint clamps free-tier limit to plan-safe maximum")
    func ratiosEndpointClampsFreeTierLimit() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, _) = try await registerTestUser(app: app, identifier: "ratiosclamp")

            try await app.testing().test(.GET, "v1/market/ratios/META?limit=10&period=FY", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            let lastRequest = await fmpState.lastRatiosRequest()
            #expect(lastRequest?.symbol == "META")
            #expect(lastRequest?.limit == 5)
            #expect(lastRequest?.period == "FY")
        }
    }

    @Test("Ratios endpoint returns 402 for symbols outside free-tier FMP coverage")
    func ratiosEndpointReturnsPaymentRequiredForUnsupportedFreeTierSymbol() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, _) = try await registerTestUser(app: app, identifier: "ratiosplanlimit")

            try await app.testing().test(.GET, "v1/market/ratios/ZETA", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                #expect(res.body.string.contains("FMP free-tier coverage for ratios"))
            })

            #expect(await fmpState.lastRatiosRequest() == nil)
        }
    }

    @Test("Analysis endpoint returns 402 for symbols outside free-tier FMP coverage")
    func analysisEndpointReturnsPaymentRequiredForUnsupportedFreeTierSymbol() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState, fmpAccessTier: .free)
            let (token, _) = try await registerTestUser(app: app, identifier: "analysisplanlimit")

            try await app.testing().test(.GET, "v1/market/analysis/ZETA", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .paymentRequired)
                #expect(res.body.string.contains("FMP free-tier coverage for analysis"))
            })

            #expect(await state.basicFinancialsCalls() == 0)
            #expect(await fmpState.ratiosTTMCalls() == 0)
            #expect(await fmpState.lastFinancialGrowthRequest() == nil)
        }
    }

    @Test("Historical sector performance endpoint forwards FMP filters")
    func historicalSectorPerformanceEndpoint() async throws {
        try await withApp { app in
            let state = TestMarketProviderState()
            let fmpState = TestFMPProviderState()
            app.marketDataService = makeTestMarketService(state: state, fmpState: fmpState)
            let (token, _) = try await registerTestUser(app: app, identifier: "sectorperf")

            try await app.testing().test(
                .GET,
                "v1/market/historical-sector-performance?sector=Energy&exchange=NASDAQ&from=2024-02-01&to=2024-03-01",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = .init(token: token)
                },
                afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let body = try res.content.decode([HistoricalSectorPerformanceResponse].self)
                    #expect(body.count == 1)
                    #expect(body.first?.sector == "Energy")
                    #expect(body.first?.exchange == "NASDAQ")
                    #expect(body.first?.averageChange == 0.6397534025664513)
                }
            )

            let lastRequest = await fmpState.lastSectorPerformanceRequest()
            #expect(lastRequest?.sector == "Energy")
            #expect(lastRequest?.exchange == "NASDAQ")
            #expect(lastRequest?.from == "2024-02-01")
            #expect(lastRequest?.to == "2024-03-01")
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

            try await app.testing().test(.GET, "v1/market/quote/batch?symbols=AAPL, msft ,aapl", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode(QuoteBatchResponse.self)
            })

            try await app.testing().test(.GET, "v1/market/quote/batch?symbols=MSFT,AAPL", beforeRequest: { req in
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

            try await app.testing().test(.GET, "v1/market/history/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode(HistoryResponse.self)
            })

            try await app.testing().test(.GET, "v1/market/history/AAPL", beforeRequest: { req in
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

            try await app.testing().test(.GET, "v1/market/search?q=AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                first = try res.content.decode([SearchResultResponse].self)
            })

            try await app.testing().test(.GET, "v1/market/search?q=AAPL", beforeRequest: { req in
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
            try await app.testing().test(.GET, "v1/market/quote/AAPL", beforeRequest: { req in
                req.headers.bearerAuthorization = .init(token: token)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                response = try res.content.decode(QuoteResponse.self)
            })

            #expect(response?.symbol == "AAPL")
            #expect(response?.currentPrice == 123.45)
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
                        image: nil,
                        publishedAt: publishedAt
                    ),
                    ProviderNewsItem(
                        symbol: "TSLA",
                        headline: "Tesla opens a new plant",
                        source: "Reuters",
                        url: "https://example.com/news/tesla-new-plant",
                        summary: "Untracked symbol should be skipped",
                        image: nil,
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
                        image: nil,
                        publishedAt: publishedAt.addingTimeInterval(5)
                    ),
                    ProviderNewsItem(
                        symbol: "TSLA",
                        headline: "Tesla opens a new plant",
                        source: "Reuters",
                        url: "https://example.com/news/tesla-new-plant",
                        summary: "Untracked symbol should still be skipped",
                        image: nil,
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

            #expect(response?.totalValue == 2_100)
            #expect(response?.dailyChange == 0)
            #expect(response?.dailyChangePercent == 0)

            #expect(response?.topPerformers.count == 2)
            #expect(response?.topPerformers.first?.symbol == "AAPL")
            #expect(response?.topPerformers.first?.change == 0)
            #expect(response?.topPerformers.first?.changePercent == 0)

            #expect(response?.bottomPerformers.count == 2)
            #expect(response?.bottomPerformers.first?.symbol == "AAPL")

            #expect(response?.sectorAllocation.count == 1)
            #expect(response?.sectorAllocation.first?.sector == "Unknown")
            #expect(response?.sectorAllocation.first?.value == 2_100)
            #expect(response?.sectorAllocation.first?.percent == 100)
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
    private var basicFinancialsCallCount: Int = 0
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

    func nextBasicFinancialsCall() -> Int {
        basicFinancialsCallCount += 1
        return basicFinancialsCallCount
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

    func basicFinancialsCalls() -> Int {
        basicFinancialsCallCount
    }
}

struct FinancialGrowthRequestCapture: Sendable, Equatable {
    let symbol: String
    let limit: Int?
    let period: String?
}

struct SectorPerformanceRequestCapture: Sendable, Equatable {
    let sector: String
    let exchange: String?
    let from: String?
    let to: String?
}

struct AnalystEstimatesRequestCapture: Sendable, Equatable {
    let symbol: String
    let period: String
    let page: Int?
    let limit: Int?
}

struct EarningsRequestCapture: Sendable, Equatable {
    let symbol: String
    let limit: Int?
}

struct EarningsCalendarRequestCapture: Sendable, Equatable {
    let from: String?
    let to: String?
}

actor TestFMPProviderState {
    private var balanceSheetRequests: [FinancialGrowthRequestCapture] = []
    private var cashFlowRequests: [FinancialGrowthRequestCapture] = []
    private var ratiosTTMCallCount: Int = 0
    private var gradesConsensusCallCount: Int = 0
    private var financialGrowthRequests: [FinancialGrowthRequestCapture] = []
    private var analystEstimatesRequests: [AnalystEstimatesRequestCapture] = []
    private var ratiosRequests: [FinancialGrowthRequestCapture] = []
    private var earningsRequests: [EarningsRequestCapture] = []
    private var earningsCalendarRequests: [EarningsCalendarRequestCapture] = []
    private var sectorPerformanceRequests: [SectorPerformanceRequestCapture] = []

    func nextRatiosTTMCall() -> Int {
        ratiosTTMCallCount += 1
        return ratiosTTMCallCount
    }

    func nextGradesConsensusCall() -> Int {
        gradesConsensusCallCount += 1
        return gradesConsensusCallCount
    }

    func recordFinancialGrowth(symbol: String, limit: Int?, period: String?) {
        financialGrowthRequests.append(.init(symbol: symbol, limit: limit, period: period))
    }

    func recordRatios(symbol: String, limit: Int?, period: String?) {
        ratiosRequests.append(.init(symbol: symbol, limit: limit, period: period))
    }

    func recordAnalystEstimates(symbol: String, period: String, page: Int?, limit: Int?) {
        analystEstimatesRequests.append(.init(symbol: symbol, period: period, page: page, limit: limit))
    }

    func recordEarnings(symbol: String, limit: Int?) {
        earningsRequests.append(.init(symbol: symbol, limit: limit))
    }

    func recordEarningsCalendar(from: String?, to: String?) {
        earningsCalendarRequests.append(.init(from: from, to: to))
    }

    func recordBalanceSheet(symbol: String, limit: Int?, period: String?) {
        balanceSheetRequests.append(.init(symbol: symbol, limit: limit, period: period))
    }

    func recordCashFlow(symbol: String, limit: Int?, period: String?) {
        cashFlowRequests.append(.init(symbol: symbol, limit: limit, period: period))
    }

    func recordSectorPerformance(sector: String, exchange: String?, from: String?, to: String?) {
        sectorPerformanceRequests.append(.init(sector: sector, exchange: exchange, from: from, to: to))
    }

    func ratiosTTMCalls() -> Int {
        ratiosTTMCallCount
    }

    func gradesConsensusCalls() -> Int {
        gradesConsensusCallCount
    }

    func lastFinancialGrowthRequest() -> FinancialGrowthRequestCapture? {
        financialGrowthRequests.last
    }

    func lastRatiosRequest() -> FinancialGrowthRequestCapture? {
        ratiosRequests.last
    }

    func lastAnalystEstimatesRequest() -> AnalystEstimatesRequestCapture? {
        analystEstimatesRequests.last
    }

    func lastBalanceSheetRequest() -> FinancialGrowthRequestCapture? {
        balanceSheetRequests.last
    }

    func lastCashFlowRequest() -> FinancialGrowthRequestCapture? {
        cashFlowRequests.last
    }

    func earningsCalls() -> Int {
        earningsRequests.count
    }

    func earningsCalendarCalls() -> Int {
        earningsCalendarRequests.count
    }

    func lastSectorPerformanceRequest() -> SectorPerformanceRequestCapture? {
        sectorPerformanceRequests.last
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

    func basicFinancials(symbol: String, on req: Request) async throws -> MarketProviderBasicFinancials? {
        _ = await state.nextBasicFinancialsCall()
        return MarketProviderBasicFinancials(
            symbol: symbol,
            metricType: "all",
            metric: [
                "52WeekHigh": .number(190.25),
                "52WeekLow": .number(164.10),
                "52WeekLowDate": .string("2026-01-14"),
                "beta": .number(1.2989),
                "forwardPE": .number(28.0),
                "epsGrowthTTMYoy": .number(12.0),
                "revenueGrowthTTMYoy": .number(10.0),
                "epsGrowthQuarterlyYoy": .number(8.0),
                "revenueGrowthQuarterlyYoy": .number(7.0),
                "grossMarginTTM": .number(60.63),
                "netProfitMarginTTM": .number(24.20)
            ],
            series: [
                "annual": [
                    "currentRatio": [
                        BasicFinancialSeriesPoint(period: "2025-09-28", value: 1.5401),
                        BasicFinancialSeriesPoint(period: "2024-09-29", value: 1.1329)
                    ]
                ]
            ]
        )
    }
}

struct TestFMPMarketDataProvider: FMPMarketDataProvider {
    let state: TestFMPProviderState

    var name: String { "test-fmp" }

    func cashFlowStatement(
        symbol: String,
        limit: Int?,
        period: String?,
        on req: Request
    ) async throws -> [CashFlowStatementResponse] {
        await state.recordCashFlow(symbol: symbol, limit: limit, period: period)
        return [
            CashFlowStatementResponse(
                date: "2024-09-28",
                symbol: symbol,
                reportedCurrency: "USD",
                cik: "0000320193",
                filingDate: "2024-11-01",
                acceptedDate: "2024-11-01 06:01:36",
                fiscalYear: "2024",
                period: period ?? "FY",
                netIncome: 93_736_000_000,
                depreciationAndAmortization: 11_445_000_000,
                deferredIncomeTax: 0,
                stockBasedCompensation: 11_688_000_000,
                changeInWorkingCapital: 3_651_000_000,
                accountsReceivables: -5_144_000_000,
                inventory: -1_046_000_000,
                accountsPayables: 6_020_000_000,
                otherWorkingCapital: 3_821_000_000,
                otherNonCashItems: -2_266_000_000,
                netCashProvidedByOperatingActivities: 118_254_000_000,
                investmentsInPropertyPlantAndEquipment: -9_447_000_000,
                acquisitionsNet: 0,
                purchasesOfInvestments: -48_656_000_000,
                salesMaturitiesOfInvestments: 62_346_000_000,
                otherInvestingActivities: -1_308_000_000,
                netCashProvidedByInvestingActivities: 2_935_000_000,
                netDebtIssuance: -5_998_000_000,
                longTermNetDebtIssuance: -9_958_000_000,
                shortTermNetDebtIssuance: 3_960_000_000,
                netStockIssuance: -94_949_000_000,
                netCommonStockIssuance: -94_949_000_000,
                commonStockIssuance: 0,
                commonStockRepurchased: -94_949_000_000,
                netPreferredStockIssuance: 0,
                netDividendsPaid: -15_234_000_000,
                commonDividendsPaid: -15_234_000_000,
                preferredDividendsPaid: 0,
                otherFinancingActivities: -5_802_000_000,
                netCashProvidedByFinancingActivities: -121_983_000_000,
                effectOfForexChangesOnCash: 0,
                netChangeInCash: -794_000_000,
                cashAtEndOfPeriod: 29_943_000_000,
                cashAtBeginningOfPeriod: 30_737_000_000,
                operatingCashFlow: 118_254_000_000,
                capitalExpenditure: -9_447_000_000,
                freeCashFlow: 108_807_000_000,
                incomeTaxesPaid: 26_102_000_000,
                interestPaid: 0
            )
        ]
    }

    func balanceSheetStatement(
        symbol: String,
        limit: Int?,
        period: String?,
        on req: Request
    ) async throws -> [BalanceSheetStatementResponse] {
        await state.recordBalanceSheet(symbol: symbol, limit: limit, period: period)
        return [
            BalanceSheetStatementResponse(
                date: "2024-09-28",
                symbol: symbol,
                reportedCurrency: "USD",
                cik: "0000320193",
                filingDate: "2024-11-01",
                acceptedDate: "2024-11-01 06:01:36",
                fiscalYear: "2024",
                period: period ?? "FY",
                cashAndCashEquivalents: 29_943_000_000,
                shortTermInvestments: 35_228_000_000,
                cashAndShortTermInvestments: 65_171_000_000,
                netReceivables: 66_243_000_000,
                accountsReceivables: 33_410_000_000,
                otherReceivables: 32_833_000_000,
                inventory: 7_286_000_000,
                prepaids: 0,
                otherCurrentAssets: 14_287_000_000,
                totalCurrentAssets: 152_987_000_000,
                propertyPlantEquipmentNet: 45_680_000_000,
                goodwill: 0,
                intangibleAssets: 0,
                goodwillAndIntangibleAssets: 0,
                longTermInvestments: 91_479_000_000,
                taxAssets: 19_499_000_000,
                otherNonCurrentAssets: 55_335_000_000,
                totalNonCurrentAssets: 211_993_000_000,
                otherAssets: 0,
                totalAssets: 364_980_000_000,
                totalPayables: 95_561_000_000,
                accountPayables: 68_960_000_000,
                otherPayables: 26_601_000_000,
                accruedExpenses: 0,
                shortTermDebt: 20_879_000_000,
                capitalLeaseObligationsCurrent: 1_632_000_000,
                taxPayables: 26_601_000_000,
                deferredRevenue: 8_249_000_000,
                otherCurrentLiabilities: 50_071_000_000,
                totalCurrentLiabilities: 176_392_000_000,
                longTermDebt: 85_750_000_000,
                deferredRevenueNonCurrent: 10_798_000_000,
                deferredTaxLiabilitiesNonCurrent: 0,
                otherNonCurrentLiabilities: 35_090_000_000,
                totalNonCurrentLiabilities: 131_638_000_000,
                otherLiabilities: 0,
                capitalLeaseObligations: 12_430_000_000,
                totalLiabilities: 308_030_000_000,
                treasuryStock: 0,
                preferredStock: 0,
                commonStock: 83_276_000_000,
                retainedEarnings: -19_154_000_000,
                additionalPaidInCapital: 0,
                accumulatedOtherComprehensiveIncomeLoss: -7_172_000_000,
                otherTotalStockholdersEquity: 0,
                totalStockholdersEquity: 56_950_000_000,
                totalEquity: 56_950_000_000,
                minorityInterest: 0,
                totalLiabilitiesAndTotalEquity: 364_980_000_000,
                totalInvestments: 126_707_000_000,
                totalDebt: 106_629_000_000,
                netDebt: 76_686_000_000
            )
        ]
    }

    func ratiosTTM(symbol: String, on req: Request) async throws -> [RatiosTTMResponse] {
        _ = await state.nextRatiosTTMCall()
        return [
            RatiosTTMResponse(
                symbol: symbol,
                grossProfitMarginTTM: 0.46518849807964424,
                ebitMarginTTM: 0.3175535678188801,
                ebitdaMarginTTM: 0.34705882352941175,
                operatingProfitMarginTTM: 0.3175535678188801,
                pretaxProfitMarginTTM: 0.31773296947645036,
                continuousOperationsProfitMarginTTM: 0.24295027289266222,
                netProfitMarginTTM: 0.24295027289266222,
                bottomLineProfitMarginTTM: 0.24295027289266222,
                receivablesTurnoverTTM: 6.673186524129093,
                payablesTurnoverTTM: 3.4187853335486995,
                inventoryTurnoverTTM: 30.626103313558097,
                fixedAssetTurnoverTTM: 8.590592372311098,
                assetTurnoverTTM: 1.1501809145995903,
                currentRatioTTM: 0.9229383853427077,
                quickRatioTTM: 0.8750666712845911,
                solvencyRatioTTM: 0.3888081578786054,
                cashRatioTTM: 0.20987774044955496,
                priceToEarningsRatioTTM: 32.889608822880916,
                priceToEarningsGrowthRatioTTM: 9.104441715061135,
                forwardPriceToEarningsGrowthRatioTTM: 9.104441715061135,
                priceToBookRatioTTM: 47.370141231313106,
                priceToSalesRatioTTM: 7.958949686678795,
                priceToFreeCashFlowRatioTTM: 32.04339747098139,
                priceToOperatingCashFlowRatioTTM: 29.201395167968677,
                debtToAssetsRatioTTM: 0.28132292892744526,
                debtToEquityRatioTTM: 1.4499985020521886,
                debtToCapitalRatioTTM: 0.5918364851397372,
                longTermDebtToCapitalRatioTTM: 0.557055084464615,
                financialLeverageRatioTTM: 5.154213727193745,
                workingCapitalTurnoverRatioTTM: -22.92267593397046,
                operatingCashFlowRatioTTM: 0.7501402694558931,
                operatingCashFlowSalesRatioTTM: 0.2736355366889024,
                freeCashFlowOperatingCashFlowRatioTTM: 0.9077049513361775,
                debtServiceCoverageRatioTTM: 8.390251498870981,
                interestCoverageRatioTTM: 0,
                shortTermOperatingCashFlowCoverageRatioTTM: 8.432142022891847,
                operatingCashFlowCoverageRatioTTM: 1.1187512267688715,
                capitalExpenditureCoverageRatioTTM: 10.834817408704351,
                dividendPaidAndCapexCoverageRatioTTM: 4.287173396674584,
                dividendPayoutRatioTTM: 0.15876235049401977,
                dividendYieldTTM: 0.0047691720717283476,
                enterpriseValueTTM: 3_216_333_928_000,
                revenuePerShareTTM: 26.24103186081379,
                netIncomePerShareTTM: 6.375265851569754,
                interestDebtPerShareTTM: 6.418298067250137,
                cashPerShareTTM: 3.565573803101025,
                bookValuePerShareTTM: 4.426417032959892,
                tangibleBookValuePerShareTTM: 4.426417032959892,
                shareholdersEquityPerShareTTM: 4.426417032959892,
                operatingCashFlowPerShareTTM: 7.180478836504368,
                capexPerShareTTM: 0.6627226436447186,
                freeCashFlowPerShareTTM: 6.5177561928596495,
                netIncomePerEBTTTM: 0.7646366484818603,
                ebtPerEbitTTM: 1.0005649492739208,
                priceToFairValueTTM: 47.370141231313106,
                debtToMarketCapTTM: 0.030731461471514124,
                effectiveTaxRateTTM: 0.23536335151813975,
                enterpriseValueMultipleTTM: 23.41672438697653
            )
        ]
    }

    func gradesConsensus(symbol: String, on req: Request) async throws -> [GradesConsensusResponse] {
        _ = await state.nextGradesConsensusCall()
        return [
            GradesConsensusResponse(
                symbol: symbol,
                strongBuy: 1,
                buy: 49,
                hold: 11,
                sell: 0,
                strongSell: 0,
                consensus: "Buy"
            )
        ]
    }

    func financialGrowth(
        symbol: String,
        limit: Int?,
        period: String?,
        on req: Request
    ) async throws -> [FinancialGrowthResponse] {
        await state.recordFinancialGrowth(symbol: symbol, limit: limit, period: period)
        return [
            FinancialGrowthResponse(
                symbol: symbol,
                date: "2024-09-28",
                fiscalYear: "2024",
                period: period ?? "FY",
                reportedCurrency: "USD",
                revenueGrowth: 0.020219940775141214,
                grossProfitGrowth: 0.06819471705252206,
                ebitgrowth: 0.07799581805933456,
                operatingIncomeGrowth: 0.07799581805933456,
                netIncomeGrowth: -0.033599670086086914,
                epsgrowth: -0.008116883116883088,
                epsdilutedGrowth: -0.008156606851549727,
                weightedAverageSharesGrowth: -0.02543458616683152,
                weightedAverageSharesDilutedGrowth: -0.02557791606880283,
                dividendsPerShareGrowth: 0.040371570095532654,
                operatingCashFlowGrowth: 0.06975566069312394,
                receivablesGrowth: 0.08621792243994425,
                inventoryGrowth: 0.15084504817564365,
                assetGrowth: 0.035160515396374756,
                bookValueperShareGrowth: -0.059693251557224776,
                debtGrowth: -0.0401393489845888,
                rdexpenseGrowth: 0.04863780712017383,
                sgaexpensesGrowth: 0.04672709770575967,
                freeCashFlowGrowth: 0.092615279562982,
                tenYRevenueGrowthPerShare: 2.3937532854122625,
                fiveYRevenueGrowthPerShare: 0.8093292228858464,
                threeYRevenueGrowthPerShare: 0.163506592883552,
                tenYOperatingCFGrowthPerShare: 2.1417809176982403,
                fiveYOperatingCFGrowthPerShare: 1.051533221923415,
                threeYOperatingCFGrowthPerShare: 0.23720294833900227,
                tenYNetIncomeGrowthPerShare: 2.76381558093543,
                fiveYNetIncomeGrowthPerShare: 1.0421744314966246,
                threeYNetIncomeGrowthPerShare: 0.07761907162786884,
                tenYShareholdersEquityGrowthPerShare: -0.19003774225234785,
                fiveYShareholdersEquityGrowthPerShare: -0.24235004889283715,
                threeYShareholdersEquityGrowthPerShare: -0.017459858915902907,
                tenYDividendperShareGrowthPerShare: 1.1722201809466772,
                fiveYDividendperShareGrowthPerShare: 0.29890046876764864,
                threeYDividendperShareGrowthPerShare: 0.14617932692103452,
                ebitdaGrowth: nil,
                growthCapitalExpenditure: nil,
                tenYBottomLineNetIncomeGrowthPerShare: nil,
                fiveYBottomLineNetIncomeGrowthPerShare: nil,
                threeYBottomLineNetIncomeGrowthPerShare: nil
            ),
            FinancialGrowthResponse(
                symbol: symbol,
                date: "2023-09-28",
                fiscalYear: "2023",
                period: period ?? "FY",
                reportedCurrency: "USD",
                revenueGrowth: 0.031,
                grossProfitGrowth: 0.05,
                ebitgrowth: 0.06,
                operatingIncomeGrowth: 0.06,
                netIncomeGrowth: 0.04,
                epsgrowth: 0.041,
                epsdilutedGrowth: 0.04,
                weightedAverageSharesGrowth: -0.02,
                weightedAverageSharesDilutedGrowth: -0.02,
                dividendsPerShareGrowth: 0.03,
                operatingCashFlowGrowth: 0.05,
                receivablesGrowth: 0.04,
                inventoryGrowth: 0.06,
                assetGrowth: 0.03,
                bookValueperShareGrowth: -0.04,
                debtGrowth: -0.02,
                rdexpenseGrowth: 0.03,
                sgaexpensesGrowth: 0.04,
                freeCashFlowGrowth: 0.08,
                tenYRevenueGrowthPerShare: 2.1,
                fiveYRevenueGrowthPerShare: 0.7,
                threeYRevenueGrowthPerShare: 0.15,
                tenYOperatingCFGrowthPerShare: 1.9,
                fiveYOperatingCFGrowthPerShare: 0.9,
                threeYOperatingCFGrowthPerShare: 0.21,
                tenYNetIncomeGrowthPerShare: 2.2,
                fiveYNetIncomeGrowthPerShare: 0.9,
                threeYNetIncomeGrowthPerShare: 0.07,
                tenYShareholdersEquityGrowthPerShare: -0.16,
                fiveYShareholdersEquityGrowthPerShare: -0.22,
                threeYShareholdersEquityGrowthPerShare: -0.01,
                tenYDividendperShareGrowthPerShare: 1.0,
                fiveYDividendperShareGrowthPerShare: 0.25,
                threeYDividendperShareGrowthPerShare: 0.13,
                ebitdaGrowth: nil,
                growthCapitalExpenditure: nil,
                tenYBottomLineNetIncomeGrowthPerShare: nil,
                fiveYBottomLineNetIncomeGrowthPerShare: nil,
                threeYBottomLineNetIncomeGrowthPerShare: nil
            )
        ]
    }

    func analystEstimates(
        symbol: String,
        period: String,
        page: Int?,
        limit: Int?,
        on req: Request
    ) async throws -> [AnalystEstimatesResponse] {
        await state.recordAnalystEstimates(symbol: symbol, period: period, page: page, limit: limit)
        return [
            AnalystEstimatesResponse(
                symbol: symbol,
                date: "2029-09-28",
                revenueLow: 483092500000,
                revenueHigh: 483093500000,
                revenueAvg: 483093000000,
                ebitdaLow: 155952166036,
                ebitdaHigh: 155952488856,
                ebitdaAvg: 155952327446,
                ebitLow: 140628295747,
                ebitHigh: 140628586847,
                ebitAvg: 140628441297,
                netIncomeLow: 139446957701,
                netIncomeHigh: 157185372990,
                netIncomeAvg: 149150359609,
                sgaExpenseLow: 31694652812,
                sgaExpenseHigh: 31694718420,
                sgaExpenseAvg: 31694685616,
                epsAvg: 9.68,
                epsHigh: 10.20148,
                epsLow: 9.05024,
                numAnalystsRevenue: 16,
                numAnalystsEps: 6
            )
        ]
    }

    func ratios(
        symbol: String,
        limit: Int?,
        period: String?,
        on req: Request
    ) async throws -> [RatiosResponse] {
        await state.recordRatios(symbol: symbol, limit: limit, period: period)
        return [
            RatiosResponse(
                symbol: symbol,
                date: "2024-09-28",
                fiscalYear: "2024",
                period: period ?? "FY",
                reportedCurrency: "USD",
                grossProfitMargin: 0.4620634981523393,
                ebitMargin: 0.31510222870075566,
                ebitdaMargin: 0.3443707085043538,
                operatingProfitMargin: 0.31510222870075566,
                pretaxProfitMargin: 0.3157901466620635,
                continuousOperationsProfitMargin: 0.23971255769943867,
                netProfitMargin: 0.23971255769943867,
                bottomLineProfitMargin: 0.23971255769943867,
                receivablesTurnover: 5.903038811648023,
                payablesTurnover: 3.0503480278422272,
                inventoryTurnover: 28.870710952511665,
                fixedAssetTurnover: 8.560310858143607,
                assetTurnover: 1.0713874732862074,
                currentRatio: 0.8673125765340832,
                quickRatio: 0.8260068483831466,
                solvencyRatio: 0.3414634938155374,
                cashRatio: 0.16975259648963673,
                priceToEarningsRatio: 37.287278415656736,
                priceToEarningsGrowthRatio: -45.93792700808932,
                forwardPriceToEarningsGrowthRatio: -45.93792700808932,
                priceToBookRatio: 61.37243774486391,
                priceToSalesRatio: 8.93822887866815,
                priceToFreeCashFlowRatio: 32.12256867269569,
                priceToOperatingCashFlowRatio: 29.55638142954995,
                debtToAssetsRatio: 0.29215025480848267,
                debtToEquityRatio: 1.872326602282704,
                debtToCapitalRatio: 0.6518501763673821,
                longTermDebtToCapitalRatio: 0.6009110021023125,
                financialLeverageRatio: 6.408779631255487,
                workingCapitalTurnoverRatio: -31.099932397502684,
                operatingCashFlowRatio: 0.6704045534944896,
                operatingCashFlowSalesRatio: 0.3024128274962599,
                freeCashFlowOperatingCashFlowRatio: 0.9201126388959359,
                debtServiceCoverageRatio: 5.024761722304708,
                interestCoverageRatio: 0,
                shortTermOperatingCashFlowCoverageRatio: 5.663777000814215,
                operatingCashFlowCoverageRatio: 1.109022873702276,
                capitalExpenditureCoverageRatio: 12.517624642743728,
                dividendPaidAndCapexCoverageRatio: 4.7912969490701345,
                dividendPayoutRatio: 0.16252026969360758,
                dividendYield: 0.0043585983369965175,
                dividendYieldPercentage: 0.43585983369965176,
                revenuePerShare: 25.484914639368924,
                netIncomePerShare: 6.109054070954992,
                interestDebtPerShare: 6.949329249507765,
                cashPerShare: 4.247388013764271,
                bookValuePerShare: 3.711600978715614,
                tangibleBookValuePerShare: 3.711600978715614,
                shareholdersEquityPerShare: 3.711600978715614,
                operatingCashFlowPerShare: 7.706965094592383,
                capexPerShare: 0.6156891035281195,
                freeCashFlowPerShare: 7.091275991064264,
                netIncomePerEBT: 0.7590881483581001,
                ebtPerEbit: 1.0021831580314244,
                priceToFairValue: 61.37243774486391,
                debtToMarketCap: 0.03050761336980449,
                effectiveTaxRate: 0.24091185164189982,
                enterpriseValueMultiple: 26.524727497716487
            )
        ]
    }

    func earnings(symbol: String, limit: Int?, on req: Request) async throws -> [EarningsResponse] {
        await state.recordEarnings(symbol: symbol, limit: limit)
        return [
            EarningsResponse(
                symbol: symbol,
                date: "2024-10-29",
                epsActual: 1.64,
                epsEstimated: 1.60,
                revenueActual: 94930000000,
                revenueEstimated: 94400000000,
                lastUpdated: "2024-12-08"
            )
        ]
    }

    func earningsCalendar(from: Date?, to: Date?, on req: Request) async throws -> [EarningsResponse] {
        await state.recordEarningsCalendar(from: from.map(formatISODateOnly), to: to.map(formatISODateOnly))
        return [
            EarningsResponse(
                symbol: "AAPL",
                date: "2024-10-29",
                epsActual: 1.64,
                epsEstimated: 1.60,
                revenueActual: 94930000000,
                revenueEstimated: 94400000000,
                lastUpdated: "2024-12-08"
            )
        ]
    }

    func historicalSectorPerformance(
        sector: String,
        exchange: String?,
        from: Date?,
        to: Date?,
        on req: Request
    ) async throws -> [HistoricalSectorPerformanceResponse] {
        await state.recordSectorPerformance(
            sector: sector,
            exchange: exchange,
            from: from.map(formatISODateOnly),
            to: to.map(formatISODateOnly)
        )
        return [
            HistoricalSectorPerformanceResponse(
                date: "2024-02-01",
                sector: sector,
                exchange: exchange ?? "NASDAQ",
                averageChange: 0.6397534025664513
            )
        ]
    }

    func fetchGeneralMarketNews(
        page: Int?,
        limit: Int?,
        from: Date?,
        to: Date?,
        on req: Request
    ) async throws -> [FMPMarketNewsItem] {
        []
    }
}

private func formatISODateOnly(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

struct TestPaymentRequiredFMPMarketDataProvider: FMPMarketDataProvider {
    let name: String = "test-fmp-payment-required"

    func cashFlowStatement(
        symbol: String,
        limit: Int?,
        period: String?,
        on req: Request
    ) async throws -> [CashFlowStatementResponse] {
        []
    }

    func balanceSheetStatement(
        symbol: String,
        limit: Int?,
        period: String?,
        on req: Request
    ) async throws -> [BalanceSheetStatementResponse] {
        []
    }

    func ratiosTTM(symbol: String, on req: Request) async throws -> [RatiosTTMResponse] {
        []
    }

    func gradesConsensus(symbol: String, on req: Request) async throws -> [GradesConsensusResponse] {
        throw Abort(
            .paymentRequired,
            reason: "FMP plan upgrade required for /stable/grades-consensus. This endpoint is not available for the requested symbol on the current subscription."
        )
    }

    func financialGrowth(
        symbol: String,
        limit: Int?,
        period: String?,
        on req: Request
    ) async throws -> [FinancialGrowthResponse] {
        []
    }

    func analystEstimates(
        symbol: String,
        period: String,
        page: Int?,
        limit: Int?,
        on req: Request
    ) async throws -> [AnalystEstimatesResponse] {
        []
    }

    func ratios(
        symbol: String,
        limit: Int?,
        period: String?,
        on req: Request
    ) async throws -> [RatiosResponse] {
        []
    }

    func earnings(symbol: String, limit: Int?, on req: Request) async throws -> [EarningsResponse] {
        []
    }

    func earningsCalendar(from: Date?, to: Date?, on req: Request) async throws -> [EarningsResponse] {
        []
    }

    func historicalSectorPerformance(
        sector: String,
        exchange: String?,
        from: Date?,
        to: Date?,
        on req: Request
    ) async throws -> [HistoricalSectorPerformanceResponse] {
        []
    }

    func fetchGeneralMarketNews(
        page: Int?,
        limit: Int?,
        from: Date?,
        to: Date?,
        on req: Request
    ) async throws -> [FMPMarketNewsItem] {
        []
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

    func basicFinancials(symbol: String, on req: Request) async throws -> MarketProviderBasicFinancials? {
        throw Abort(.badGateway, reason: "Forced market provider failure")
    }
}
