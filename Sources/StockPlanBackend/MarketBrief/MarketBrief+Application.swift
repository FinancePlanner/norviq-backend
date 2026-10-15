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

    private struct MarketBriefPushEnabledKey: StorageKey {
        typealias Value = Bool
    }

    private struct MarketBriefNotificationPreferenceServiceKey: StorageKey {
        typealias Value = any MarketBriefNotificationPreferenceServicing
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

    /// `MARKET_BRIEF_PUSH_ENABLED`. Whether the job pushes a written slot to
    /// opted-in users. Off by default, independent of `marketBriefEnabled`.
    var marketBriefPushEnabled: Bool {
        get { storage[MarketBriefPushEnabledKey.self] ?? false }
        set { storage[MarketBriefPushEnabledKey.self] = newValue }
    }

    var marketBriefNotificationPreferenceService: any MarketBriefNotificationPreferenceServicing {
        get { storage[MarketBriefNotificationPreferenceServiceKey.self] ?? DatabaseMarketBriefNotificationPreferenceService() }
        set { storage[MarketBriefNotificationPreferenceServiceKey.self] = newValue }
    }
}
