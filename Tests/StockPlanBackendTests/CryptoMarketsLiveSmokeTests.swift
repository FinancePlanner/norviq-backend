import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

/// Live contract check against CoinGecko (and FMP when a key is set). Opt-in
/// because it makes real network calls against rate-limited APIs:
///
///     CRYPTO_MARKETS_LIVE_SMOKE=1 [COINGECKO_API_KEY=...] [FMP_API_KEY=...] \
///         swift test --filter CryptoMarketsLiveSmoke
///
/// Every CoinGecko field is optional on our side, so a renamed key would not
/// fail decoding — it would silently blank a column. This asserts the columns
/// the view depends on are actually populated.
@Suite(
    "Crypto markets live smoke",
    .enabled(if: ProcessInfo.processInfo.environment["CRYPTO_MARKETS_LIVE_SMOKE"] == "1")
)
struct CryptoMarketsLiveSmokeTests {
    @Test("a live refresh produces a usable snapshot")
    func liveRefresh() async throws {
        let env = ProcessInfo.processInfo.environment
        // Mirror configure(): the app decodes with a global snake_case-rewriting
        // decoder, and this test once passed only because it skipped that.
        ContentConfiguration.global.use(decoder: JSONDecoder.backendAPI, for: .json)
        let app = try await Application.make(.testing)
        do {
            let fmpKey = env["FMP_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
            let service = DefaultCryptoMarketsService(
                provider: CoinGeckoV3CryptoMarketsProvider(apiKey: env["COINGECKO_API_KEY"], plan: .demo),
                reference: fmpKey.map { FMPCryptoReferenceDataSource(provider: LiveFMPMarketDataProvider(apiKey: $0)) },
                cache: InMemoryAIResponseCache(),
                universeSize: 100,
                freshTTLSeconds: 600
            )
            let req = Request(application: app, on: app.eventLoopGroup.next())
            let snapshot = try await service.refreshSnapshot(ytdFillBudget: 5, on: req)

            #expect(snapshot.coins.count >= 50)
            #expect(snapshot.coins.first?.id == "bitcoin")
            #expect(!snapshot.coins.contains { $0.id == "tether" || $0.id == "usd-coin" })
            let bitcoin = try #require(snapshot.coins.first { $0.id == "bitcoin" })
            #expect(bitcoin.returns.oneDay != nil)
            #expect(bitcoin.returns.oneWeek != nil)
            #expect(bitcoin.returns.oneMonth != nil)
            #expect(bitcoin.athChangePct != nil)
            #expect(bitcoin.sparkline7d.count == CryptoMarketsAssembler.sparklinePoints)
            #expect(bitcoin.sector == "Layer 1")
            if fmpKey != nil {
                #expect(bitcoin.fmpSymbol == "BTCUSD")
                #expect(bitcoin.returns.yearToDate != nil, "YTD base should fill for the largest coin")
            }

            let response = try await service.markets(timeframe: .oneWeek, limit: 50, on: req)
            #expect(response.coins.count == 50)
            #expect(!response.gainers.isEmpty || !response.losers.isEmpty)
            print("live smoke: coins=\(snapshot.coins.count) btc 1w=\(bitcoin.returns.oneWeek ?? .nan) ytd=\(bitcoin.returns.yearToDate ?? .nan) gainers=\(response.gainers.map(\.symbol)) dominance=\(snapshot.btcDominancePct ?? .nan)")
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
