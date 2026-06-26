import Vapor

private struct StatisticsRepositoryKey: StorageKey {
    typealias Value = any StatisticsRepository
}

private struct StatisticsServiceKey: StorageKey {
    typealias Value = any StatisticsService
}

extension Application {
    var statisticsRepository: any StatisticsRepository {
        get { storage[StatisticsRepositoryKey.self]! }
        set { storage[StatisticsRepositoryKey.self] = newValue }
    }

    var statisticsService: any StatisticsService {
        get { storage[StatisticsServiceKey.self]! }
        set { storage[StatisticsServiceKey.self] = newValue }
    }
}
