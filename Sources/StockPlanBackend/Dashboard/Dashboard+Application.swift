import Vapor

extension Application {
    struct DashboardRepositoryKey: StorageKey {
        typealias Value = any DashboardRepository
    }

    struct DashboardServiceKey: StorageKey {
        typealias Value = any DashboardService
    }

    var dashboardRepository: any DashboardRepository {
        get { storage[DashboardRepositoryKey.self]! }
        set { storage[DashboardRepositoryKey.self] = newValue }
    }

    var dashboardService: any DashboardService {
        get { storage[DashboardServiceKey.self]! }
        set { storage[DashboardServiceKey.self] = newValue }
    }
}
