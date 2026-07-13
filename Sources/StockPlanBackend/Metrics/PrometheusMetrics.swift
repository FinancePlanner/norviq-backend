import Atomics
import Foundation

/// Central singleton for Prometheus metric values.
///
/// All values are stored in lock-free atomics so they can be safely
/// incremented from any thread. The `render()` method produces a
/// Prometheus exposition text payload.
final class PrometheusMetrics: @unchecked Sendable {
    static let shared = PrometheusMetrics()
    private init() {}

    // MARK: - HTTP

    /// Total number of HTTP requests received (counter)
    let httpRequestsTotal = ManagedAtomic<Int64>(0 as Int64)

    /// Current number of in-flight HTTP requests (gauge)
    let httpInflight = ManagedAtomic<Int64>(0 as Int64)

    // MARK: - Latency histogram

    private static let bucketBounds: [Double] = [
        0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10,
    ]
    private let latencyBucketCounts: [ManagedAtomic<Int64>] = PrometheusMetrics.bucketBounds.map { _ in ManagedAtomic<Int64>(0 as Int64) }

    let latencySum = ManagedAtomic<Int64>(0 as Int64) // attoseconds
    let latencyCount = ManagedAtomic<Int64>(0 as Int64)

    // MARK: - Business

    let stocksCreated = ManagedAtomic<Int64>(0 as Int64)
    let portfoliosCreated = ManagedAtomic<Int64>(0 as Int64)
    let transactionsCreated = ManagedAtomic<Int64>(0 as Int64)
    let targetsCreated = ManagedAtomic<Int64>(0 as Int64)
    let scenarioRunsCompleted = ManagedAtomic<Int64>(0)
    let scenarioRunsFailed = ManagedAtomic<Int64>(0)
    let scenarioCacheHits = ManagedAtomic<Int64>(0)
    let scenarioPathsTotal = ManagedAtomic<Int64>(0)
    let scenarioQueueDepth = ManagedAtomic<Int64>(0)
    let scenarioDurationMilliseconds = ManagedAtomic<Int64>(0)
    let scenarioProxyUsage = ManagedAtomic<Int64>(0)
    let scenarioMissingHistory = ManagedAtomic<Int64>(0)
    let scenarioHistoryBarsCovered = ManagedAtomic<Int64>(0)
    let scenarioHistoryBarsExpected = ManagedAtomic<Int64>(0)
    let taxCarryforwardReconciliations = ManagedAtomic<Int64>(0)
    let taxCarryforwardGeneratedCents = ManagedAtomic<Int64>(0)
    let taxCarryforwardAppliedCents = ManagedAtomic<Int64>(0)

    // MARK: - Recording

    func incrementRequestsTotal() {
        httpRequestsTotal.wrappingIncrement(by: 1, ordering: .relaxed)
    }

    func incrementInflight() {
        httpInflight.wrappingIncrement(by: 1, ordering: .relaxed)
    }

    func decrementInflight() {
        httpInflight.wrappingDecrement(by: 1, ordering: .relaxed)
    }

    func recordRequestDuration(_ duration: Duration) {
        let components = duration.components
        let attos = Int64(components.attoseconds)
        latencySum.wrappingIncrement(by: attos, ordering: .relaxed)
        latencyCount.wrappingIncrement(by: 1, ordering: .relaxed)
        let secs = Double(components.seconds) + Double(attos) / 1e18
        for (i, bound) in Self.bucketBounds.enumerated() {
            if secs <= bound {
                latencyBucketCounts[i].wrappingIncrement(by: 1, ordering: .relaxed)
                break
            }
        }
    }

    // MARK: - Business increments

    func incrementStocksCreated() {
        stocksCreated.wrappingIncrement(by: 1, ordering: .relaxed)
    }

    func incrementPortfoliosCreated() {
        portfoliosCreated.wrappingIncrement(by: 1, ordering: .relaxed)
    }

    func incrementTransactionsCreated() {
        transactionsCreated.wrappingIncrement(by: 1, ordering: .relaxed)
    }

    func incrementTargetsCreated() {
        targetsCreated.wrappingIncrement(by: 1, ordering: .relaxed)
    }

    func recordScenarioCompleted(paths: Int, duration: Duration) {
        scenarioRunsCompleted.wrappingIncrement(ordering: .relaxed)
        scenarioPathsTotal.wrappingIncrement(by: Int64(paths), ordering: .relaxed)
        let components = duration.components
        let milliseconds = components.seconds * 1000 + Int64(components.attoseconds / 1_000_000_000_000_000)
        scenarioDurationMilliseconds.wrappingIncrement(by: milliseconds, ordering: .relaxed)
    }

    func recordScenarioFailed() {
        scenarioRunsFailed.wrappingIncrement(ordering: .relaxed)
    }

    func recordScenarioCacheHit() {
        scenarioCacheHits.wrappingIncrement(ordering: .relaxed)
    }

    func setScenarioQueueDepth(_ value: Int) {
        scenarioQueueDepth.store(Int64(value), ordering: .relaxed)
    }

    func recordScenarioDataQuality(proxyCount: Int, missingHistoryCount: Int) {
        scenarioProxyUsage.wrappingIncrement(by: Int64(proxyCount), ordering: .relaxed)
        scenarioMissingHistory.wrappingIncrement(by: Int64(missingHistoryCount), ordering: .relaxed)
    }

    func recordScenarioHistoryCoverage(covered: Int, expected: Int) {
        scenarioHistoryBarsCovered.wrappingIncrement(by: Int64(max(0, covered)), ordering: .relaxed)
        scenarioHistoryBarsExpected.wrappingIncrement(by: Int64(max(0, expected)), ordering: .relaxed)
    }

    func recordTaxCarryforwardReconciliation(generated: Decimal, applied: Decimal) {
        taxCarryforwardReconciliations.wrappingIncrement(ordering: .relaxed)
        let generatedCents = NSDecimalNumber(decimal: max(0, generated) * 100).int64Value
        let appliedCents = NSDecimalNumber(decimal: max(0, applied) * 100).int64Value
        taxCarryforwardGeneratedCents.wrappingIncrement(by: generatedCents, ordering: .relaxed)
        taxCarryforwardAppliedCents.wrappingIncrement(by: appliedCents, ordering: .relaxed)
    }

    // MARK: - Render

    /// Render all registered metric values as Prometheus text format.
    func render() -> String {
        var out = ""

        // HTTP requests total
        out.append("# HELP http_requests_total Total number of HTTP requests received.\n")
        out.append("# TYPE http_requests_total counter\n")
        out.append("http_requests_total \(httpRequestsTotal.load(ordering: .relaxed))\n\n")

        // HTTP inflight gauge
        out.append("# HELP http_inflight_requests Current number of in-flight HTTP requests.\n")
        out.append("# TYPE http_inflight_requests gauge\n")
        out.append("http_inflight_requests \(httpInflight.load(ordering: .relaxed))\n\n")

        // HTTP request duration histogram
        out.append("# HELP http_request_duration_seconds Histogram of HTTP request latency in seconds.\n")
        out.append("# TYPE http_request_duration_seconds histogram\n")
        for (i, bound) in Self.bucketBounds.enumerated() {
            let le = String(format: "%.3f", bound)
            let count = latencyBucketCounts[i].load(ordering: .relaxed)
            out.append("http_request_duration_seconds_bucket{le=\"\(le)\"} \(count)\n")
        }
        // +Inf bucket
        let total = latencyCount.load(ordering: .relaxed)
        out.append("http_request_duration_seconds_bucket{le=\"+Inf\"} \(total)\n")
        let sumAttos = latencySum.load(ordering: .relaxed)
        let sumSecs = Double(sumAttos) / 1e18
        out.append("http_request_duration_seconds_sum \(String(format: "%.6f", sumSecs))\n")
        out.append("http_request_duration_seconds_count \(total)\n\n")

        // Business metrics
        out.append("# HELP stocks_created_total Number of stocks created via POST /v1/stocks.\n")
        out.append("# TYPE stocks_created_total counter\n")
        out.append("stocks_created_total \(stocksCreated.load(ordering: .relaxed))\n\n")

        out.append("# HELP portfolios_created_total Number of portfolio lists created via POST /v1/portfolios.\n")
        out.append("# TYPE portfolios_created_total counter\n")
        out.append("portfolios_created_total \(portfoliosCreated.load(ordering: .relaxed))\n\n")

        out.append("# HELP transactions_created_total Number of transactions created (including broker syncs).\n")
        out.append("# TYPE transactions_created_total counter\n")
        out.append("transactions_created_total \(transactionsCreated.load(ordering: .relaxed))\n\n")

        out.append("# HELP targets_created_total Number of investment targets created via POST /v1/targets.\n")
        out.append("# TYPE targets_created_total counter\n")
        out.append("targets_created_total \(targetsCreated.load(ordering: .relaxed))\n")
        out.append("\n# TYPE scenario_runs_completed_total counter\nscenario_runs_completed_total \(scenarioRunsCompleted.load(ordering: .relaxed))\n")
        out.append("# TYPE scenario_runs_failed_total counter\nscenario_runs_failed_total \(scenarioRunsFailed.load(ordering: .relaxed))\n")
        out.append("# TYPE scenario_result_cache_hits_total counter\nscenario_result_cache_hits_total \(scenarioCacheHits.load(ordering: .relaxed))\n")
        out.append("# TYPE scenario_simulation_paths_total counter\nscenario_simulation_paths_total \(scenarioPathsTotal.load(ordering: .relaxed))\n")
        out.append("# TYPE scenario_queue_depth gauge\nscenario_queue_depth \(scenarioQueueDepth.load(ordering: .relaxed))\n")
        out.append("# TYPE scenario_run_duration_milliseconds_total counter\nscenario_run_duration_milliseconds_total \(scenarioDurationMilliseconds.load(ordering: .relaxed))\n")
        out.append("# TYPE scenario_proxy_usage_total counter\nscenario_proxy_usage_total \(scenarioProxyUsage.load(ordering: .relaxed))\n")
        out.append("# TYPE scenario_missing_history_total counter\nscenario_missing_history_total \(scenarioMissingHistory.load(ordering: .relaxed))\n")
        let covered = scenarioHistoryBarsCovered.load(ordering: .relaxed)
        let expected = scenarioHistoryBarsExpected.load(ordering: .relaxed)
        let coverage = expected > 0 ? Double(covered) / Double(expected) : 0
        let coverageText = String(format: "%.6f", coverage)
        out.append("# TYPE scenario_history_coverage_ratio gauge\nscenario_history_coverage_ratio \(coverageText)\n")
        out.append("# TYPE tax_carryforward_reconciliations_total counter\ntax_carryforward_reconciliations_total \(taxCarryforwardReconciliations.load(ordering: .relaxed))\n")
        out.append("# TYPE tax_carryforward_generated_cents_total counter\ntax_carryforward_generated_cents_total \(taxCarryforwardGeneratedCents.load(ordering: .relaxed))\n")
        out.append("# TYPE tax_carryforward_applied_cents_total counter\ntax_carryforward_applied_cents_total \(taxCarryforwardAppliedCents.load(ordering: .relaxed))\n")

        return out
    }
}
