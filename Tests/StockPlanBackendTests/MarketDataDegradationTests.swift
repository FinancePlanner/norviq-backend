@testable import StockPlanBackend
import Testing
import Vapor

@Suite("Market data degradation")
struct MarketDataDegradationTests {
    @Test(
        "Plan, coverage, and malformed-body answers degrade to an empty result",
        arguments: [
            HTTPResponseStatus.notFound,
            .paymentRequired,
            .unauthorized,
            .forbidden,
            // FMPMarketDataProvider.fetchJSON reports both a 401/403 and a decode
            // failure as 502, so 502 has to degrade for the decode case to.
            .badGateway,
        ]
    )
    func missingDataStatusesDegrade(status: HTTPResponseStatus) {
        #expect(MarketDataDegradation.isMissingData(Abort(status)))
    }

    @Test(
        "A misconfiguration or a real fault is not missing data",
        arguments: [
            HTTPResponseStatus.serviceUnavailable,
            .internalServerError,
            .tooManyRequests,
            .requestTimeout,
        ]
    )
    func otherStatusesDoNotDegrade(status: HTTPResponseStatus) {
        #expect(!MarketDataDegradation.isMissingData(Abort(status)))
    }

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
