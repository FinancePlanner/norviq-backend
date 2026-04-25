import Vapor

/// Middleware that records HTTP request metrics for Prometheus export.
///
/// Updates in-flight gauge and records latency histogram.
struct HTTPMetricsMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let metrics = PrometheusMetrics.shared
        metrics.incrementInflight()
        defer { metrics.decrementInflight() }

        let start = ContinuousClock.now
        let response = try await next.respond(to: request)
        let duration = ContinuousClock.now.duration(to: start)

        metrics.incrementRequestsTotal()
        metrics.recordRequestDuration(duration)

        return response
    }
}
