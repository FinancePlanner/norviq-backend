import Fluent
import Vapor

/// The one operator allowlist, for Insights admin, Boards moderation and the
/// social moderation queue alike. Fail-closed: with no list configured nobody
/// is an admin. `NORVIQ_ADMIN_EMAILS` wins when set; otherwise the legacy
/// per-feature lists (`INSIGHTS_ADMIN_EMAILS`, which production has sealed, and
/// `SOCIAL_MODERATOR_EMAILS`) are read together.
enum AdminGuard {
    static func adminEmails() -> Set<String> {
        let primary = envEmailSet("NORVIQ_ADMIN_EMAILS")
        guard primary.isEmpty else { return primary }
        return envEmailSet("INSIGHTS_ADMIN_EMAILS").union(envEmailSet("SOCIAL_MODERATOR_EMAILS"))
    }

    static func isAdmin(_ user: User) -> Bool {
        adminEmails().contains(user.email.lowercased())
    }

    /// Throws 403 unless the session's user is on the allowlist.
    @discardableResult
    static func requireAdmin(_ req: Request) async throws -> User {
        let session = try req.auth.require(SessionToken.self)
        guard !adminEmails().isEmpty else {
            throw Abort(.forbidden, reason: "Admin access is disabled (no admin emails configured).")
        }
        guard let user = try await User.find(session.userId, on: req.db), isAdmin(user) else {
            throw Abort(.forbidden, reason: "Admin access required.")
        }
        return user
    }
}

struct AdminOnlyMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        try await AdminGuard.requireAdmin(request)
        return try await next.respond(to: request)
    }
}
