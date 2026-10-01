@testable import StockPlanBackend
import Testing
import Vapor

@Suite("Crypto provider selection")
struct CryptoProviderSelectionTests {
    @Test("production without an FMP key is disabled, never mock")
    func productionWithoutKeyIsDisabled() {
        let provider = makeCryptoDataProvider(fmp: nil, environment: .production)
        #expect(provider is DisabledCryptoDataProvider)
    }

    @Test("staging-style environments without an FMP key are disabled")
    func customEnvironmentWithoutKeyIsDisabled() {
        let provider = makeCryptoDataProvider(fmp: nil, environment: .custom(name: "staging"))
        #expect(provider is DisabledCryptoDataProvider)
    }

    @Test("development and testing fall back to the mock")
    func developmentWithoutKeyIsMock() {
        #expect(makeCryptoDataProvider(fmp: nil, environment: .development) is MockCryptoDataProvider)
        #expect(makeCryptoDataProvider(fmp: nil, environment: .testing) is MockCryptoDataProvider)
    }

    @Test("a configured FMP provider always wins")
    func fmpProviderWins() {
        let fmp = LiveFMPMarketDataProvider(apiKey: "test-key")
        #expect(makeCryptoDataProvider(fmp: fmp, environment: .production) is LiveFMPMarketDataProvider)
        #expect(makeCryptoDataProvider(fmp: fmp, environment: .development) is LiveFMPMarketDataProvider)
    }
}
