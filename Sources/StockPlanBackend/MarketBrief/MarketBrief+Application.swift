import Vapor

extension Application {
    private struct MarketBriefRepositoryKey: StorageKey {
        typealias Value = any MarketBriefRepository
    }

    private struct MarketBriefGeneratorKey: StorageKey {
        typealias Value = any MarketBriefGenerating
    }

    private struct MarketBriefEnabledKey: StorageKey {
        typealias Value = Bool
    }

    var marketBriefRepository: any MarketBriefRepository {
        get { storage[MarketBriefRepositoryKey.self] ?? DatabaseMarketBriefRepository() }
        set { storage[MarketBriefRepositoryKey.self] = newValue }
    }

    /// Built on every boot so the operator command works with the flag off.
    var marketBriefGenerator: (any MarketBriefGenerating)? {
        get { storage[MarketBriefGeneratorKey.self] }
        set { storage[MarketBriefGeneratorKey.self] = newValue }
    }

    /// `MARKET_BRIEF_ENABLED`. Gates the scheduled job and what the route
    /// serves. Stored here rather than read per request so tests can flip it.
    var marketBriefEnabled: Bool {
        get { storage[MarketBriefEnabledKey.self] ?? false }
        set { storage[MarketBriefEnabledKey.self] = newValue }
    }
}
