import Vapor

/// Adds `Vary: Origin` header when CORS headers are present.
/// Ensures CDNs and intermediate caches treat responses as varying by Origin.
struct VaryHeaderMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        // If CORS headers exist, add Vary: Origin.
        if response.headers.contains(name: "access-control-allow-origin") {
            response.headers.add(name: "Vary", value: "Origin")
        }
        return response
    }
}
