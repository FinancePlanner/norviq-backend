import Vapor

extension Application {
    struct AIInsightsServiceKey: StorageKey {
        typealias Value = any AIInsightsService
    }

    var aiInsightsService: any AIInsightsService {
        get { storage[AIInsightsServiceKey.self]! }
        set { storage[AIInsightsServiceKey.self] = newValue }
    }
}
