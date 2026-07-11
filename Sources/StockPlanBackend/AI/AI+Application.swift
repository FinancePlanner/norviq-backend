import Vapor

extension Application {
    struct AIInsightsServiceKey: StorageKey {
        typealias Value = any AIInsightsService
    }

    var aiInsightsService: any AIInsightsService {
        get { storage[AIInsightsServiceKey.self]! }
        set { storage[AIInsightsServiceKey.self] = newValue }
    }

    struct AIChatServiceKey: StorageKey {
        typealias Value = any AIChatService
    }

    var aiChatService: any AIChatService {
        get { storage[AIChatServiceKey.self]! }
        set { storage[AIChatServiceKey.self] = newValue }
    }
}
