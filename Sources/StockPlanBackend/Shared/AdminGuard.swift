import Fluent
import Vapor

/// The one operator allowlist, for Insights admin, Boards moderation and the
/// social moderation queue alike: `NORVIQ_ADMIN_USER_IDS`, comma-separated
/// user UUIDs. Fail-closed: with no list configured nobody is an admin, and an
/// entry that is not a UUID grants nothing.
///
/// Keyed by user id, never by email. An email allowlist let anyone claim an
/// allowlisted address that had no account yet (or change their email to it)
/// and become an admin. The old `NORVIQ_ADMIN_EMAILS`, `INSIGHTS_ADMIN_EMAILS`
/// and `SOCIAL_MODERATOR_EMAILS` lists are no longer read.
enum AdminGuard {
    static func adminUserIDs() -> Set<UUID> {
        guard let rawValue = Environment.get("NORVIQ_ADMIN_USER_IDS") else {
            return []
        }
        return Set(
            rawValue
                .split(separator: ",")
                .compactMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        )
    }

    static func isAdmin(userId: UUID) -> Bool {
        adminUserIDs().contains(userId)
    }

    static func isAdmin(_ user: User) -> Bool {
        user.id.map(isAdmin(userId:)) ?? false
    }

    /// Throws 403 unless the session's user is on the allowlist.
    @discardableResult
    static func requireAdmin(_ req: Request) async throws -> User {
        let session = try req.auth.require(SessionToken.self)
        guard !adminUserIDs().isEmpty else {
            throw Abort(.forbidden, reason: "Admin access is disabled (no admin user ids configured).")
        }
        guard isAdmin(userId: session.userId), let user = try await User.find(session.userId, on: req.db) else {
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
