import Fluent
import Vapor

/// Operator-only endpoint exposing the total user count for the portfolio
/// dashboard at facorreia.com/apps.
///
/// Distinct from `MetricsController`, which serves Prometheus exposition at
/// `/metrics`. This one lives at `/internal/metrics` and is guarded by the
/// shared secret in the METRICS_SECRET environment variable.
struct InternalMetricsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("internal", "metrics", use: userCount)
    }

    @Sendable
    func userCount(req: Request) async throws -> InternalMetricsResponse {
        guard let secret = Environment.get("METRICS_SECRET"), !secret.isEmpty else {
            throw Abort(.internalServerError, reason: "METRICS_SECRET is not configured")
        }

        // Constant-time comparison: the length check leaks only the length,
        // and zip walks every byte regardless of where the first mismatch is.
        let presented = req.headers.bearerAuthorization?.token ?? ""
        let presentedBytes = Array(presented.utf8)
        let secretBytes = Array(secret.utf8)
        guard presentedBytes.count == secretBytes.count else {
            throw Abort(.unauthorized)
        }
        var diff: UInt8 = 0
        for (a, b) in zip(presentedBytes, secretBytes) {
            diff |= a ^ b
        }
        guard diff == 0 else {
            throw Abort(.unauthorized)
        }

        let count = try await User.query(on: req.db).count()
        return InternalMetricsResponse(users: count)
    }
}

struct InternalMetricsResponse: Content {
    let users: Int
}
