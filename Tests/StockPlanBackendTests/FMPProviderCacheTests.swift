import Foundation
@testable import StockPlanBackend
import StockPlanShared
import Testing
import Vapor

@Suite("FMP provider cache and rate limiting")
struct FMPProviderCacheTests {
    private static let eodBody = #"[{"symbol":"AAPL","date":"2026-10-07","price":231.5,"volume":1000}]"#

    private func provider(cache: InMemoryAIResponseCache = InMemoryAIResponseCache()) -> LiveFMPMarketDataProvider {
        LiveFMPMarketDataProvider(baseURL: "http://stub", apiKey: "test-key", responseCache: cache, eodTTLSeconds: 3600)
    }

    @Test("Repeated EOD history for the same range is served from cache")
    func eodHistoryIsCached() async throws {
        let stub = AnthropicStubHTTP([(.ok, Self.eodBody)])
        let fmp = provider()
        try await stub.withRequest { req in
            let first = try await fmp.stockHistoricalEOD(symbol: "aapl", from: "2026-09-08", to: "2026-10-08", on: req)
            let second = try await fmp.stockHistoricalEOD(symbol: "AAPL", from: "2026-09-08", to: "2026-10-08", on: req)

            #expect(first == second)
            #expect(first.first?.price == 231.5)
        }
        #expect(stub.requests.count == 1)
    }

    @Test("A different range is a different cache entry")
    func differentRangeFetchesAgain() async throws {
        let stub = AnthropicStubHTTP([(.ok, Self.eodBody)])
        let fmp = provider()
        try await stub.withRequest { req in
            _ = try await fmp.stockHistoricalEOD(symbol: "AAPL", from: "2026-09-08", to: "2026-10-08", on: req)
            _ = try await fmp.stockHistoricalEOD(symbol: "AAPL", from: "2025-10-08", to: "2026-10-08", on: req)
        }
        #expect(stub.requests.count == 2)
    }

    @Test("429 surfaces as rate limited and later calls fail fast without reaching FMP")
    func rateLimitedFailsFast() async throws {
        let stub = AnthropicStubHTTP([(.tooManyRequests, #"{"Error Message":"Limit Reach"}"#)])
        let fmp = provider()
        try await stub.withRequest { req in
            await #expect(throws: MarketDataProviderRateLimitedError.self) {
                _ = try await fmp.stockHistoricalEOD(symbol: "AAPL", from: "2026-09-08", to: "2026-10-08", on: req)
            }
            await #expect(throws: MarketDataProviderRateLimitedError.self) {
                _ = try await fmp.stockHistoricalEOD(symbol: "MSFT", from: "2026-09-08", to: "2026-10-08", on: req)
            }
        }
        #expect(stub.requests.count == 1)
    }

    @Test("A failed fetch is not cached")
    func failuresAreNotCached() async throws {
        let stub = AnthropicStubHTTP([(.internalServerError, "{}"), (.ok, Self.eodBody)])
        let fmp = provider()
        try await stub.withRequest { req in
            await #expect(throws: (any Error).self) {
                _ = try await fmp.stockHistoricalEOD(symbol: "AAPL", from: "2026-09-08", to: "2026-10-08", on: req)
            }
            let points = try await fmp.stockHistoricalEOD(symbol: "AAPL", from: "2026-09-08", to: "2026-10-08", on: req)
            #expect(points.count == 1)
        }
        #expect(stub.requests.count == 2)
    }

    @Test("Ranges that ended before today are kept longer than ones reaching today")
    func ttlByRangeEnd() throws {
        let fmp = provider()
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-09T12:00:00Z"))

        #expect(fmp.eodCacheTTL(to: "2026-10-08", now: now) == LiveFMPMarketDataProvider.closedRangeTTLSeconds)
        #expect(fmp.eodCacheTTL(to: "2026-10-09", now: now) == 3600)
        #expect(fmp.eodCacheTTL(to: nil, now: now) == 3600)
    }
}
