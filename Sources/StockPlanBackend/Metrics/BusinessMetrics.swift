import Foundation

/// Business metrics facade (exposes increment methods).
///
/// Acts as a thin wrapper around the underlying PrometheusMetrics singleton.
struct BusinessMetrics {
    static let shared = BusinessMetrics()
    init() {}

    func incrementStocksCreated() {
        PrometheusMetrics.shared.incrementStocksCreated()
    }

    func incrementPortfoliosCreated() {
        PrometheusMetrics.shared.incrementPortfoliosCreated()
    }

    func incrementTransactionsCreated() {
        PrometheusMetrics.shared.incrementTransactionsCreated()
    }

    func incrementTargetsCreated() {
        PrometheusMetrics.shared.incrementTargetsCreated()
    }
}
