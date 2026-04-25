import Vapor
import HTTPTypes

/// Controller exposing a Prometheus `/metrics` endpoint.
///
/// Collects metrics from the in-process `PrometheusMetrics` singleton
/// and renders them in Prometheus exposition text format.
struct MetricsController: RouteCollection {
    init() {}

    func boot(routes: any RoutesBuilder) throws {
        routes.get("metrics", use: getMetrics)
    }

    func getMetrics(req: Request) async throws -> Response {
        let body = PrometheusMetrics.shared.render()
        var response = Response(status: .ok, body: .init(string: body))
        response.headers.contentType = HTTPMediaType.plainText
        response.headers.contentType?.parameters["charset"] = "utf-8"
        return response
    }
}
