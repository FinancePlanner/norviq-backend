@testable import StockPlanBackend
import Testing
import Vapor

@Suite("Market data degradation")
struct MarketDataDegradationTests {
    @Test(
        "Every status the provider can hand this layer degrades, except 503",
        arguments: [
            // The two statuses fetchJSON passes through unchanged.
            (HTTPResponseStatus.notFound, true),
            (.paymentRequired, true),
            // Everything else fetchJSON can raise is a 502: a 401, a 403, a
            // decode failure, and — through its `default:` branch — an upstream
            // 429, 500 or 503. They are one status by the time they reach here.
            (.badGateway, true),
            // The one it raises that must not degrade: a missing FMP_API_KEY,
            // and the ownership services' own "no FMP provider configured".
            (.serviceUnavailable, false),
        ]
    )
    func statusesTheProviderCanRaise(status: HTTPResponseStatus, degrades: Bool) {
        #expect(MarketDataDegradation.isMissingData(Abort(status)) == degrades)
    }

    /// `isMissingData` also answers false for 401, 403, 429 and 500, but no
    /// caller can reach it with one: `fetchJSON` has already rewritten each of
    /// them. Asserting those in isolation would read as "a rate limit surfaces
    /// as an error", which is the opposite of what happens, so the claim is
    /// pinned end-to-end instead — see `MarketOwnershipServiceTests`,
    /// "An upstream rate limit degrades to an empty result, like any other
    /// failure".
    @Test("A non-HTTP error is not missing data")
    func nonHTTPErrorsDoNotDegrade() {
        struct Boom: Error {}

        #expect(!MarketDataDegradation.isMissingData(Boom()))
    }

    @Test("A feature logs its degradation once, however many requests hit it")
    func aFeatureLogsOnce() {
        let gate = OnceLogGate()

        #expect(gate.shouldLog("market.insider"))
        #expect(!gate.shouldLog("market.insider"))
        #expect(!gate.shouldLog("market.insider"))
    }

    @Test("Each feature gets its own first warning")
    func eachFeatureGetsItsOwnFirstWarning() {
        let gate = OnceLogGate()

        #expect(gate.shouldLog("market.insider"))
        #expect(gate.shouldLog("market.congress"))
        #expect(!gate.shouldLog("market.insider"))
    }
}
