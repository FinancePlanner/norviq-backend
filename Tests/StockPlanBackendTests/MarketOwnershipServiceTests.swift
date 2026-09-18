import Foundation
import Redis
@testable import StockPlanBackend
import Testing
import Vapor
import VaporTesting

// MARK: - Suite

/// The wiring the pure calculation suites cannot see: which upstream calls the
/// service makes, when it stops making them, and what it writes to the cache.
@Suite("Market ownership service", .serialized)
struct MarketOwnershipServiceTests {
    // MARK: Harness

    /// Boots a configured app, hands the test a stub-backed service and a
    /// detached request, and tears down.
    ///
    /// No migrations: none of the three ownership features touches `req.db`,
    /// and skipping them keeps this suite off the database lock.
    ///
    /// `configureDatabase` disables Redis in `.testing` on purpose, so every
    /// other suite can run without one. This suite opts back in, because the
    /// "do not cache a degraded response" rule is a statement about Redis and
    /// there is no injectable fake behind `MarketDataService.redisSetValue`.
    /// Nothing else in the suite uses Redis in testing, so this cannot disturb
    /// another test, and every test here uses a fresh symbol rather than
    /// flushing the database out from under one.
    private func withService(
        _ test: (OwnershipStub, any MarketDataService, Request, Application) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            if let url = Environment.get("REDIS_URL"), !url.isEmpty,
               let configuration = try? RedisConfiguration(url: url)
            {
                app.redis.configuration = configuration
            }
            // Redis connection pools are created by the boot lifecycle, not by
            // assigning the configuration; without this the first `req.redis`
            // traps rather than returning a miss.
            try await app.asyncBoot()
            let stub = OwnershipStub()
            let service = DefaultMarketDataService(
                provider: DisabledMarketDataProvider(),
                fmpProvider: OwnershipStubProvider(state: stub),
                cacheConfig: .init(
                    quoteTTLSeconds: 3600,
                    historyTTLSeconds: 3600,
                    searchTTLSeconds: 3600,
                    fxTTLSeconds: 3600,
                    profileTTLSeconds: 3600,
                    basicFinancialsTTLSeconds: 3600,
                    fmpTTLSeconds: 3600,
                    ownershipTTLSeconds: 3600,
                    defaultCurrency: "USD"
                )
            )
            let req = Request(
                application: app,
                method: .GET,
                url: URI(string: "/internal/ownership-test"),
                on: app.eventLoopGroup.next()
            )
            try await test(stub, service, req, app)
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }

    /// Drops one cache entry, for the tests whose key cannot be made unique.
    private func clearCache(_ key: String, app: Application) async {
        guard app.redis.configuration != nil else { return }
        _ = try? await app.redis.delete(RedisKey(key)).get()
    }

    /// A symbol no other test in the run uses, so a Redis entry left by an
    /// earlier run or an earlier test cannot answer this one.
    private func uniqueSymbol() -> String {
        "T" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).uppercased()
    }

    private func insiderRow(date: String, name: String) -> FMPInsiderTrade {
        FMPInsiderTrade(
            symbol: "AAPL",
            filingDate: date,
            transactionDate: date,
            transactionType: "P-Purchase",
            securitiesTransacted: 100,
            securitiesOwned: nil,
            price: 10,
            reportingName: name,
            typeOfOwner: nil,
            acquisitionOrDisposition: nil,
            url: nil
        )
    }

    /// `count` rows, all inside a 365-day window ending today.
    private func recentRows(_ count: Int) -> [FMPInsiderTrade] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt

        return (0 ..< count).map { index in
            let day = calendar.date(byAdding: .day, value: -(index % 30), to: Date()) ?? Date()
            return insiderRow(date: formatter.string(from: day), name: "Insider \(index)")
        }
    }

    private func holder(_ name: String, shares: Double) -> FMPInstitutionalHolder {
        FMPInstitutionalHolder(
            investorName: name,
            sharesNumber: shares,
            marketValue: nil,
            changeInSharesNumber: nil,
            changeInSharesNumberPercentage: nil,
            weight: nil
        )
    }

    // MARK: - Insider pagination: the three ways the walk stops

    @Test("A short page ends the walk, because there is no next page")
    func aShortPageEndsTheWalk() async throws {
        try await withService { stub, service, req, _ in
            await stub.setInsiderPages([0: recentRows(40)])

            let response = try await service.insiderActivity(symbol: uniqueSymbol(), windowDays: 365, on: req)

            #expect(await stub.insiderPagesRequested == [0])
            #expect(response.trades.count == 40)
        }
    }

    @Test("A full page whose oldest row predates the window ends the walk")
    func aPageOlderThanTheWindowEndsTheWalk() async throws {
        try await withService { stub, service, req, _ in
            var page = recentRows(InsiderActivityConfig.pageSize)
            page[InsiderActivityConfig.pageSize - 1] = insiderRow(date: "2019-01-02", name: "Ancient")
            await stub.setInsiderPages([0: page, 1: recentRows(InsiderActivityConfig.pageSize)])

            let response = try await service.insiderActivity(symbol: uniqueSymbol(), windowDays: 365, on: req)

            #expect(await stub.insiderPagesRequested == [0])
            // The out-of-window row is fetched but not published.
            #expect(response.trades.count == InsiderActivityConfig.pageSize - 1)
        }
    }

    @Test("The walk stops at the row ceiling even when every page is full and in-window")
    func theWalkStopsAtTheRowCeiling() async throws {
        try await withService { stub, service, req, _ in
            let pages = Dictionary(
                uniqueKeysWithValues: (0 ... 9).map { ($0, recentRows(InsiderActivityConfig.pageSize)) }
            )
            await stub.setInsiderPages(pages)

            _ = try await service.insiderActivity(symbol: uniqueSymbol(), windowDays: 365, on: req)

            let expectedPages = InsiderActivityConfig.maxRows / InsiderActivityConfig.pageSize
            #expect(await stub.insiderPagesRequested == Array(0 ..< expectedPages))
        }
    }

    @Test("An empty page ends the walk without asking for the next one")
    func anEmptyPageEndsTheWalk() async throws {
        try await withService { stub, service, req, _ in
            await stub.setInsiderPages([0: recentRows(InsiderActivityConfig.pageSize), 1: []])

            _ = try await service.insiderActivity(symbol: uniqueSymbol(), windowDays: 365, on: req)

            #expect(await stub.insiderPagesRequested == [0, 1])
        }
    }

    @Test("Pages already collected survive a later page failing")
    func earlierPagesSurviveALaterFailure() async throws {
        try await withService { stub, service, req, _ in
            await stub.setInsiderPages([0: recentRows(InsiderActivityConfig.pageSize)])
            await stub.setInsiderError(Abort(.paymentRequired), onPage: 1)

            let response = try await service.insiderActivity(symbol: uniqueSymbol(), windowDays: 365, on: req)

            #expect(await stub.insiderPagesRequested == [0, 1])
            #expect(response.trades.count == InsiderActivityConfig.pageSize)
        }
    }

    // MARK: - Degradation, end to end

    @Test("An upstream rate limit degrades to an empty result, like any other failure")
    func anUpstreamRateLimitDegradesToEmpty() async throws {
        try await withService { stub, service, req, _ in
            // fetchJSON turns an upstream 429 into a 502 before the service
            // sees it, so 502 is what a throttle actually looks like here.
            await stub.setInsiderError(Abort(.badGateway), onPage: 0)

            let response = try await service.insiderActivity(symbol: uniqueSymbol(), windowDays: 365, on: req)

            #expect(response.trades.isEmpty)
            #expect(response.clusterBuy == nil)
            #expect(response.summary.buys == 0)
        }
    }

    @Test("A missing FMP_API_KEY is not degraded away")
    func aMisconfiguredProviderStillThrows() async throws {
        try await withService { stub, service, req, _ in
            await stub.setInsiderError(Abort(.serviceUnavailable), onPage: 0)

            await #expect(throws: (any Error).self) {
                _ = try await service.insiderActivity(symbol: uniqueSymbol(), windowDays: 365, on: req)
            }
        }
    }

    @Test("One chamber failing does not take the other chamber's disclosures with it")
    func oneChamberFailingKeepsTheOther() async throws {
        try await withService { stub, service, req, _ in
            let symbol = uniqueSymbol()
            await stub.setSenateError(Abort(.paymentRequired))
            await stub.setHouse([congressRow(symbol: symbol, date: "2026-06-02")])

            let response = try await service.congressTrades(symbol: symbol, on: req)

            #expect(response.trades.map(\.chamber) == [.house])
        }
    }

    @Test("Both chambers answering merges them, newest transaction first")
    func bothChambersMerge() async throws {
        try await withService { stub, service, req, _ in
            let symbol = uniqueSymbol()
            await stub.setSenate([congressRow(symbol: symbol, date: "2026-06-01")])
            await stub.setHouse([congressRow(symbol: symbol, date: "2026-06-02")])

            let response = try await service.congressTrades(symbol: symbol, on: req)

            #expect(response.trades.map(\.chamber) == [.house, .senate])
        }
    }

    // MARK: - The cache rule

    @Test("A healthy response is cached; a degraded one is not")
    func aDegradedResponseIsNotCached() async throws {
        try await withService { stub, service, req, app in
            // Needs REDIS_URL, which CI's redis:7-alpine service provides and
            // `.env` sets locally. Failing loudly rather than skipping: a
            // silent skip would make this test pass while proving nothing.
            try #require(app.redis.configuration != nil)

            // Healthy: the second call is served from Redis.
            let healthy = uniqueSymbol()
            await stub.setInsiderPages([0: recentRows(3)])
            _ = try await service.insiderActivity(symbol: healthy, windowDays: 365, on: req)
            let afterFirst = await stub.insiderPagesRequested.count
            _ = try await service.insiderActivity(symbol: healthy, windowDays: 365, on: req)
            #expect(await stub.insiderPagesRequested.count == afterFirst)

            // Degraded: the empty answer is not written, so the next request
            // tries upstream again instead of serving the emptiness for 6h.
            let degraded = uniqueSymbol()
            await stub.setInsiderError(Abort(.badGateway), onPage: 0)
            let empty = try await service.insiderActivity(symbol: degraded, windowDays: 365, on: req)
            #expect(empty.trades.isEmpty)
            let afterDegraded = await stub.insiderPagesRequested.count
            _ = try await service.insiderActivity(symbol: degraded, windowDays: 365, on: req)
            #expect(await stub.insiderPagesRequested.count > afterDegraded)
        }
    }

    // MARK: - Institutional quarter fallback

    @Test("An empty newest quarter falls back to the one before it")
    func anEmptyQuarterFallsBack() async throws {
        try await withService { stub, service, req, _ in
            let newest = MarketQuarter.latestReported()
            let previous = newest.previous()
            await stub.setHolders([holder("Fund A", shares: 100)], quarter: previous.label)

            let response = try await service.institutionalOwnership(symbol: uniqueSymbol(), on: req)

            #expect(await stub.holderQuartersRequested == [newest.label, previous.label])
            #expect(response.asOfQuarter == previous.label)
            #expect(response.topHolders.map(\.name) == ["Fund A"])
            // The totals must describe the same quarter as the holders.
            #expect(await stub.summaryQuartersRequested == [previous.label])
        }
    }

    @Test("A populated newest quarter is used as is, with no second request")
    func aPopulatedQuarterDoesNotFallBack() async throws {
        try await withService { stub, service, req, _ in
            let newest = MarketQuarter.latestReported()
            await stub.setHolders([holder("Fund A", shares: 100)], quarter: newest.label)

            let response = try await service.institutionalOwnership(symbol: uniqueSymbol(), on: req)

            #expect(await stub.holderQuartersRequested == [newest.label])
            #expect(response.asOfQuarter == newest.label)
        }
    }

    @Test("A failing holder call does not fall back, and answers empty for the newest quarter")
    func aFailingHolderCallDoesNotFallBack() async throws {
        try await withService { stub, service, req, _ in
            let newest = MarketQuarter.latestReported()
            await stub.setHoldersError(Abort(.paymentRequired))

            let response = try await service.institutionalOwnership(symbol: uniqueSymbol(), on: req)

            #expect(await stub.holderQuartersRequested == [newest.label])
            #expect(response.asOfQuarter == newest.label)
            #expect(response.topHolders.isEmpty)
        }
    }

    // MARK: - Clamping, where it is reachable

    @Test("The service clamps an out-of-range window rather than refusing it")
    func theServiceClampsTheWindow() async throws {
        try await withService { stub, service, req, _ in
            await stub.setInsiderPages([0: recentRows(1)])

            let wide = try await service.insiderActivity(symbol: uniqueSymbol(), windowDays: 5000, on: req)
            let narrow = try await service.insiderActivity(symbol: uniqueSymbol(), windowDays: 1, on: req)

            #expect(wide.windowDays == InsiderActivityConfig.windowDaysRange.upperBound)
            #expect(narrow.windowDays == InsiderActivityConfig.windowDaysRange.lowerBound)
        }
    }

    @Test("The recent feed asks each chamber for the full limit and cuts the merge back to it")
    func theRecentFeedAsksEachChamberForTheFullLimit() async throws {
        try await withService { stub, service, req, app in
            // The recent feed's cache key is the limit alone — there is no
            // symbol to make unique — so an entry left by an earlier run would
            // answer this without any upstream call.
            await clearCache(CongressTradesConfig.recentRedisKey(limit: 5), app: app)
            await stub.setSenateLatest((1 ... 4).map { congressRow(symbol: "S\($0)", date: "2026-06-0\($0)") })
            await stub.setHouseLatest((1 ... 4).map { congressRow(symbol: "H\($0)", date: "2026-05-0\($0)") })

            let response = try await service.recentCongressTrades(limit: 5, on: req)

            #expect(await stub.latestLimitsRequested.sorted() == [5, 5])
            #expect(response.trades.count == 5)
            // Senate's June trades outrank House's May ones.
            #expect(response.trades.map(\.symbol) == ["S4", "S3", "S2", "S1", "H4"])
        }
    }

    // MARK: - Helpers

    private func congressRow(symbol: String, date: String) -> FMPCongressTrade {
        FMPCongressTrade(
            symbol: symbol,
            disclosureDate: "2026-06-20",
            transactionDate: date,
            firstName: "Ann",
            lastName: "Alpha",
            office: nil,
            district: nil,
            state: nil,
            party: nil,
            owner: nil,
            assetDescription: nil,
            assetType: nil,
            type: "Purchase",
            amount: "$1,001 - $15,000",
            link: nil
        )
    }
}
