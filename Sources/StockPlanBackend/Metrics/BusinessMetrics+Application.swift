import Vapor

extension Application {
    struct BusinessMetricsKey: StorageKey {
        typealias Value = BusinessMetrics
    }

    var businessMetrics: BusinessMetrics {
        get {
            if let existing = storage[BusinessMetricsKey.self] {
                return existing
            }
            let metrics = BusinessMetrics()
            storage[BusinessMetricsKey.self] = metrics
            return metrics
        }
        set { storage[BusinessMetricsKey.self] = newValue }
    }
}
