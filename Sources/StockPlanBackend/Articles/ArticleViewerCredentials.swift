import Vapor

/// The web app's scoped credentials, from `ARTICLES_VIEWER_CREDENTIAL_IDS`
/// (comma-separated token ids). Only these may forward a visitor key in
/// `X-Norviq-Viewer`; any other third-party credential is nobody, so it can't
/// mint views by rotating the header.
enum ArticleViewerCredentials {
    static let environmentKey = "ARTICLES_VIEWER_CREDENTIAL_IDS"

    static func parse(_ raw: String?) -> Set<UUID> {
        Set((raw ?? "").split(separator: ",").compactMap {
            UUID(uuidString: $0.trimmingCharacters(in: .whitespaces))
        })
    }

    /// True when the request authenticated with one of the listed credentials.
    static func isListed(_ req: Request) -> Bool {
        guard let scope = req.auth.get(ScopeContext.self) else { return false }
        return req.application.articleViewerCredentialIds.contains(scope.tokenId)
    }
}

/// The per-user view limit, except for the listed credentials: they relay
/// every logged-out visitor, so one bucket would cap the whole site. The daily
/// per-viewer dedupe bounds what they can count instead.
struct ArticleViewRateLimitMiddleware: AsyncMiddleware {
    var limiter: any AsyncMiddleware = RateLimitMiddleware(limit: 120, interval: 60, keyPrefix: "ratelimit:article-view")

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if ArticleViewerCredentials.isListed(request) {
            return try await next.respond(to: request)
        }
        return try await limiter.respond(to: request, chainingTo: next)
    }
}

extension Application {
    private struct ArticleViewerCredentialIdsKey: StorageKey {
        typealias Value = Set<UUID>
    }

    /// Set once from the environment in `configure`.
    var articleViewerCredentialIds: Set<UUID> {
        get { storage[ArticleViewerCredentialIdsKey.self] ?? [] }
        set { storage[ArticleViewerCredentialIdsKey.self] = newValue }
    }
}
