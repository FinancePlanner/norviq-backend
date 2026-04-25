import Vapor

extension Application {
    struct BusinessMetricsKey: StorageKey {
        typealias Value = BusinessMetrics
    }

    var businessMetrics: BusinessMetrics {
        get { storage[BusinessMetricsKey.self]! }
        set { storage[BusinessMetricsKey.self] = newValue }
    }
}
