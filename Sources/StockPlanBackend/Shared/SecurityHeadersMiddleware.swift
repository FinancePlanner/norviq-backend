import Vapor

/// Adds baseline security headers to every response.
///
/// TLS termination and HSTS normally live at the reverse proxy, but the app sets them too as
/// defense-in-depth so a misconfigured or bypassed proxy does not silently drop them.
struct SecurityHeadersMiddleware: AsyncMiddleware {
    /// Emit Strict-Transport-Security only when serving production traffic; sending HSTS from
    /// a local plain-HTTP listener is meaningless and can pin developer browsers.
    let includeHSTS: Bool

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        response.headers.replaceOrAdd(name: "X-Frame-Options", value: "DENY")
        response.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
        if includeHSTS {
            response.headers.replaceOrAdd(
                name: "Strict-Transport-Security",
                value: "max-age=31536000; includeSubDomains"
            )
        }
        return response
    }
}
