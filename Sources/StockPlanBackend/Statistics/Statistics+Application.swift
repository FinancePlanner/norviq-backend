import Vapor

extension Application {
    struct StatisticsRepositoryKey: StorageKey {
        typealias Value = any StatisticsRepository
    }

    struct StatisticsServiceKey: StorageKey {
        typealias Value = any StatisticsService
    }

    var statisticsRepository: any StatisticsRepository {
        get { storage[StatisticsRepositoryKey.self]! }
        set { storage[StatisticsRepositoryKey.self] = newValue }
    }

    var statisticsService: any StatisticsService {
        get { storage[StatisticsServiceKey.self]! }
        set { storage[StatisticsServiceKey.self] = newValue }
    }
}
