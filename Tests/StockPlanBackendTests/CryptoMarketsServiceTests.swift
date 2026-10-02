import Foundation
import NIOConcurrencyHelpers
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("Crypto markets service", .serialized)
struct CryptoMarketsServiceTests {
    // MARK: - Stubs

    final class StubProvider: CryptoMarketsProvider, @unchecked Sendable {
        let name = "stub"
        let attribution: String? = "Stub data"
        private let lock = NIOLock()
        private var _universeCalls = 0
        var coins: [CryptoMarketCoin]
        var fails = false
        var excluded: Set<String> = []

        init(coins: [CryptoMarketCoin]) {
            self.coins = coins
        }

        var universeCalls: Int {
            lock.withLock { _universeCalls }
        }

        func fetchUniverse(limit _: Int, on _: Request) async throws -> [CryptoMarketCoin] {
            lock.withLock { _universeCalls += 1 }
            if fails {
                throw Abort(.tooManyRequests)
            }
            return coins
        }

        func fetchExcludedIds(on _: Request) async throws -> Set<String> {
            excluded
        }
    }

    struct StubReference: CryptoReferenceDataSource {
        var symbols: Set<String> = ["BTCUSD", "ETHUSD"]
        var yearStart: [String: Double] = ["BTCUSD": 50]

        func knownSymbols(on _: Request) async throws -> Set<String> {
            symbols
        }

        func yearStartPrice(symbol: String, year _: Int, on _: Request) async throws -> Double? {
            yearStart[symbol]
        }
    }

    /// Counts FMP history calls; fails every call when `fails` is set (the
    /// plan quota answer, "Limit Reach").
    final class CountingReference: CryptoReferenceDataSource, @unchecked Sendable {
        private let lock = NIOLock()
        private var _requested: [String] = []
        var fails = false
        var symbols: Set<String>

        init(symbols: Set<String>) {
            self.symbols = symbols
        }

        var requested: [String] {
            lock.withLock { _requested }
        }

        func knownSymbols(on _: Request) async throws -> Set<String> {
            symbols
        }

        func yearStartPrice(symbol: String, year _: Int, on _: Request) async throws -> Double? {
            lock.withLock { _requested.append(symbol) }
            if fails {
                throw Abort(.badGateway, reason: "Limit Reach")
            }
            return 10
        }
    }

    private static func ranked(_ count: Int) -> [CryptoMarketCoin] {
        (1 ... count).map { index in
            coin("coin\(index)", symbol: "C\(index)", price: 20, marketCap: Double(1000 - index) * 1e9)
        }
    }

    private static func coin(_ id: String, symbol: String, price: Double, marketCap: Double, day: Double = 1, month: Double = 10) -> CryptoMarketCoin {
        CryptoMarketCoin(
            id: id, symbol: symbol, name: id, rank: nil, sector: "Other", price: price,
            marketCap: marketCap, volume24h: 1e9,
            returns: .init(oneDay: day, oneMonth: month)
        )
    }

    private static let universe = [
        coin("bitcoin", symbol: "BTC", price: 100, marketCap: 6e11),
        coin("ethereum", symbol: "ETH", price: 10, marketCap: 3e11),
        coin("tether", symbol: "USDT", price: 1, marketCap: 1e11, day: 0, month: 0),
        coin("new-dollar", symbol: "NUSD", price: 1.001, marketCap: 5e9, day: 0.01, month: 0.1),
        coin("btc-imposter", symbol: "BTC", price: 3, marketCap: 1e8),
    ]

    private func withRequest(_ body: (Request) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await body(Request(application: app, on: app.eventLoopGroup.next()))
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func makeService(
        provider: StubProvider,
        cache: InMemoryAIResponseCache = InMemoryAIResponseCache(),
        reference: StubReference? = StubReference()
    ) -> DefaultCryptoMarketsService {
        DefaultCryptoMarketsService(
            provider: provider, reference: reference, cache: cache,
            filter: .init(minMarketCap: 0, minVolume24h: 0, listSize: 10),
            freshTTLSeconds: 600
        )
    }

    // MARK: - Tests

    @Test("refresh drops stablecoins, pegged coins and duplicate tickers")
    func refreshFilters() async throws {
        try await withRequest { req in
            let provider = StubProvider(coins: Self.universe)
            provider.excluded = ["tether"]
            let snapshot = try await makeService(provider: provider).refreshSnapshot(ytdFillBudget: 0, on: req)
            #expect(snapshot.coins.map(\.id) == ["bitcoin", "ethereum"])
            #expect(snapshot.totalMarketCap == 6e11 + 3e11 + 1e11 + 5e9 + 1e8)
            #expect(snapshot.btcDominancePct.map { ($0 * 10).rounded() / 10 } == 59.7)
        }
    }

    @Test("refresh links FMP symbols and fills YTD from the year-start price")
    func refreshEnriches() async throws {
        try await withRequest { req in
            let provider = StubProvider(coins: Self.universe)
            let snapshot = try await makeService(provider: provider).refreshSnapshot(ytdFillBudget: 25, on: req)
            let bitcoin = try #require(snapshot.coins.first { $0.id == "bitcoin" })
            #expect(bitcoin.fmpSymbol == "BTCUSD")
            #expect(bitcoin.sector == "Layer 1")
            #expect(bitcoin.returns.yearToDate == 100) // 100 now vs 50 at year start
            let ether = try #require(snapshot.coins.first { $0.id == "ethereum" })
            #expect(ether.returns.yearToDate == nil) // FMP had no history
        }
    }

    @Test("a failed YTD fetch stops the batch and pauses later refreshes")
    func ytdFailurePausesFill() async throws {
        try await withRequest { req in
            let coins = Self.ranked(10)
            let reference = CountingReference(symbols: Set(coins.map { "\($0.symbol)USD" }))
            reference.fails = true
            let service = DefaultCryptoMarketsService(
                provider: StubProvider(coins: coins), reference: reference, cache: InMemoryAIResponseCache(),
                filter: .init(minMarketCap: 0, minVolume24h: 0, listSize: 10), freshTTLSeconds: 600
            )

            _ = try await service.refreshSnapshot(ytdFillBudget: 5, on: req)
            _ = try await service.refreshSnapshot(ytdFillBudget: 5, on: req)

            #expect(reference.requested.count == 1, "one failure, then paused: \(reference.requested)")
        }
    }

    @Test("the pause is shared through the cache with other replicas")
    func ytdPauseIsShared() async throws {
        try await withRequest { req in
            let coins = Self.ranked(5)
            let cache = InMemoryAIResponseCache()
            let failing = CountingReference(symbols: Set(coins.map { "\($0.symbol)USD" }))
            failing.fails = true
            _ = try await DefaultCryptoMarketsService(
                provider: StubProvider(coins: coins), reference: failing, cache: cache, freshTTLSeconds: 600
            ).refreshSnapshot(ytdFillBudget: 5, on: req)

            let other = CountingReference(symbols: failing.symbols)
            _ = try await DefaultCryptoMarketsService(
                provider: StubProvider(coins: coins), reference: other, cache: cache, freshTTLSeconds: 600
            ).refreshSnapshot(ytdFillBudget: 5, on: req)
            #expect(other.requested.isEmpty)
        }
    }

    @Test("YTD is only fetched for the top coins, within the per-tick budget")
    func ytdCoverageAndBudget() async throws {
        try await withRequest { req in
            let coins = Self.ranked(10)
            let reference = CountingReference(symbols: Set(coins.map { "\($0.symbol)USD" }))
            let service = DefaultCryptoMarketsService(
                provider: StubProvider(coins: coins), reference: reference, cache: InMemoryAIResponseCache(),
                ytdCoverage: 3, freshTTLSeconds: 600
            )

            let first = try await service.refreshSnapshot(ytdFillBudget: 2, on: req)
            #expect(reference.requested == ["C1USD", "C2USD"])
            #expect(first.coins.filter { $0.returns.yearToDate != nil }.count == 2)

            _ = try await service.refreshSnapshot(ytdFillBudget: 2, on: req)
            _ = try await service.refreshSnapshot(ytdFillBudget: 2, on: req)
            #expect(reference.requested == ["C1USD", "C2USD", "C3USD"], "never past the coverage")
        }
    }

    @Test("without FMP no coin links to a detail page")
    func refreshWithoutReference() async throws {
        try await withRequest { req in
            let provider = StubProvider(coins: Self.universe)
            let snapshot = try await makeService(provider: provider, reference: nil).refreshSnapshot(ytdFillBudget: 25, on: req)
            #expect(snapshot.coins.allSatisfy { $0.fmpSymbol == nil })
        }
    }

    @Test("a fresh snapshot serves every timeframe without another upstream call")
    func freshHitSkipsProvider() async throws {
        try await withRequest { req in
            let provider = StubProvider(coins: Self.universe)
            let service = makeService(provider: provider)
            _ = try await service.markets(timeframe: .oneDay, limit: 100, on: req)
            let monthly = try await service.markets(timeframe: .oneMonth, limit: 100, on: req)
            #expect(provider.universeCalls == 1)
            #expect(monthly.timeframe == .oneMonth)
            #expect(monthly.isStale == false)
        }
    }

    @Test("another replica's snapshot in Redis is used before refreshing")
    func sharedCacheHit() async throws {
        try await withRequest { req in
            let cache = InMemoryAIResponseCache()
            _ = try await makeService(provider: StubProvider(coins: Self.universe), cache: cache)
                .refreshSnapshot(ytdFillBudget: 0, on: req)

            let provider = StubProvider(coins: Self.universe)
            _ = try await makeService(provider: provider, cache: cache).markets(timeframe: .oneDay, limit: 10, on: req)
            #expect(provider.universeCalls == 0)
        }
    }

    @Test("an upstream failure serves the stale copy, flagged")
    func failureServesStale() async throws {
        try await withRequest { req in
            let cache = InMemoryAIResponseCache()
            _ = try await makeService(provider: StubProvider(coins: Self.universe), cache: cache)
                .refreshSnapshot(ytdFillBudget: 0, on: req)
            // Fresh copy gone, stale copy still there.
            await cache.set(DefaultCryptoMarketsService.Keys.snapshot, value: "expired", ttlSeconds: 1, on: req)

            let failing = StubProvider(coins: [])
            failing.fails = true
            let response = try await makeService(provider: failing, cache: cache).markets(timeframe: .oneDay, limit: 10, on: req)
            #expect(response.isStale)
            #expect(response.coins.map(\.id) == ["bitcoin", "ethereum"])
        }
    }

    @Test("after an upstream failure, requests serve stale data without retrying upstream")
    func failureBacksOff() async throws {
        try await withRequest { req in
            let cache = InMemoryAIResponseCache()
            _ = try await makeService(provider: StubProvider(coins: Self.universe), cache: cache)
                .refreshSnapshot(ytdFillBudget: 0, on: req)
            await cache.set(DefaultCryptoMarketsService.Keys.snapshot, value: "expired", ttlSeconds: 1, on: req)

            let failing = StubProvider(coins: [])
            failing.fails = true
            let service = makeService(provider: failing, cache: cache)
            for _ in 0 ..< 5 {
                let response = try await service.markets(timeframe: .oneDay, limit: 10, on: req)
                #expect(response.isStale)
            }
            #expect(failing.universeCalls == 1)
        }
    }

    @Test("no data anywhere is a 502")
    func failureWithoutCacheIsBadGateway() async throws {
        try await withRequest { req in
            let failing = StubProvider(coins: [])
            failing.fails = true
            await #expect(throws: Abort.self) {
                _ = try await makeService(provider: failing).markets(timeframe: .oneDay, limit: 10, on: req)
            }
        }
    }

    /// configure() installs `JSONDecoder.backendAPI` globally, which rewrites
    /// snake_case keys before CodingKeys lookup. Decoding CoinGecko with it
    /// turned every `current_price` into nil and staging into "no coins".
    @Test("the provider decodes CoinGecko independently of the app's global decoder")
    func providerIgnoresGlobalDecoder() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/coingecko-coins-markets.json")
        let data = try Data(contentsOf: url)

        let viaBackendDecoder = try JSONDecoder.backendAPI.decode([CoinGeckoMarketItem].self, from: data)
        #expect(viaBackendDecoder.compactMap(\.marketCoin).isEmpty, "documents the trap the provider must avoid")

        let items = try CoinGeckoV3CryptoMarketsProvider.decode([CoinGeckoMarketItem].self, from: ByteBuffer(data: data))
        #expect(items.compactMap(\.marketCoin).count == items.count)
    }

    @Test("CoinGecko fixture decodes into market coins")
    func coinGeckoFixtureDecodes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/coingecko-coins-markets.json")
        let items = try JSONDecoder().decode([CoinGeckoMarketItem].self, from: Data(contentsOf: url))
        let coins = items.compactMap(\.marketCoin)
        #expect(coins.count == items.count)

        let bitcoin = try #require(coins.first { $0.id == "bitcoin" })
        #expect(bitcoin.symbol == "BTC")
        #expect(bitcoin.rank == 1)
        #expect(bitcoin.returns.oneWeek != nil)
        #expect(bitcoin.athDate.flatMap(CryptoMarketsAssembler.parseISO8601) != nil)
        #expect(bitcoin.sparkline7d.count <= CryptoMarketsAssembler.sparklinePoints)
        #expect(coins.contains { $0.returns.oneYear == nil })
    }
}
