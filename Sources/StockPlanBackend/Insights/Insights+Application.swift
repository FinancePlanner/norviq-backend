import Vapor

extension Application {
    struct InsightsRepositoryKey: StorageKey {
        typealias Value = any InsightsRepository
    }

    struct InsightsServiceKey: StorageKey {
        typealias Value = any InsightsService
    }

    struct InsightsProviderKey: StorageKey {
        typealias Value = any InsightsProvider
    }

    struct InsightsSyncStatusKey: StorageKey {
        typealias Value = InsightsSyncStatus
    }

    var insightsRepository: any InsightsRepository {
        get { storage[InsightsRepositoryKey.self]! }
        set { storage[InsightsRepositoryKey.self] = newValue }
    }

    var insightsService: any InsightsService {
        get { storage[InsightsServiceKey.self]! }
        set { storage[InsightsServiceKey.self] = newValue }
    }

    var insightsProvider: any InsightsProvider {
        get { storage[InsightsProviderKey.self]! }
        set { storage[InsightsProviderKey.self] = newValue }
    }

    var insightsSyncStatus: InsightsSyncStatus {
        get { storage[InsightsSyncStatusKey.self]! }
        set { storage[InsightsSyncStatusKey.self] = newValue }
    }
}
