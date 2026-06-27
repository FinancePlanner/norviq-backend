@testable import StockPlanBackend
import Testing

@Suite("Market provider selection tests")
struct MarketProviderSelectionTests {
    @Test("Default provider selection prefers Finnhub over broker sync URL")
    func defaultSelectionPrefersFinnhubOverIBKR() {
        #expect(
            MarketDataProviderKind.select(
                configuredMarketProvider: nil,
                hasFinnhubAPIKey: true,
                hasIBKRBaseURL: true
            ) == .finnhub
        )
        #expect(
            MarketDataProviderKind.select(
                configuredMarketProvider: "",
                hasFinnhubAPIKey: true,
                hasIBKRBaseURL: true
            ) == .finnhub
        )
    }

    @Test("Explicit IBKR provider still selects IBKR")
    func explicitIBKRProviderStillSelectsIBKR() {
        #expect(
            MarketDataProviderKind.select(
                configuredMarketProvider: "ibkr",
                hasFinnhubAPIKey: true,
                hasIBKRBaseURL: true
            ) == .ibkr
        )
    }

    @Test("Missing explicit provider configuration disables market data")
    func missingExplicitProviderConfigurationDisablesMarketData() {
        #expect(
            MarketDataProviderKind.select(
                configuredMarketProvider: "finnhub",
                hasFinnhubAPIKey: false,
                hasIBKRBaseURL: true
            ) == .disabled
        )
        #expect(
            MarketDataProviderKind.select(
                configuredMarketProvider: "ibkr",
                hasFinnhubAPIKey: true,
                hasIBKRBaseURL: false
            ) == .disabled
        )
    }
}
