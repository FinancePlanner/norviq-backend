import Fluent
import Foundation
import StockPlanShared
import Vapor

/// Who is asking, resolved once per request by `CommunityAccessMiddleware`.
/// Access tokens are stateless and live for days, so mute and ban are read
/// from the database on every request rather than baked into the token.
struct CommunityViewer: Sendable {
    let userId: UUID
    let username: String?
    let isAdmin: Bool
    let activeSanction: CommunitySanction?
    let guidelinesAccepted: Bool
    /// When a moderator suspended the user from social. A suspension removes
    /// Boards too, exactly like a ban.
    let socialSuspendedAt: Date?

    var isBanned: Bool {
        !isAdmin && (activeSanction?.kind == CommunitySanctionKind.ban.rawValue || socialSuspendedAt != nil)
    }

    var isMuted: Bool {
        !isAdmin && activeSanction?.kind == CommunitySanctionKind.mute.rawValue
    }

    /// Gate for anything that adds content or a vote. Reporting and blocking
    /// deliberately skip it: a muted user must still be able to protect
    /// themselves.
    func requireCanContribute() throws {
        if isMuted {
            var details: [String: String] = [:]
            if let expiresAt = activeSanction?.expiresAt {
                details["expiresAt"] = ISO8601DateFormatter().string(from: expiresAt)
            }
            throw CodedAbort(
                status: .forbidden,
                code: "community_muted",
                reason: "You're muted on Norviq Boards and can't post, comment or vote right now.",
                details: details.isEmpty ? nil : details
            )
        }
        guard username?.isEmpty == false else {
            throw CodedAbort(status: .forbidden, code: "username_required", reason: "Pick a username before posting.")
        }
        guard guidelinesAccepted || isAdmin else {
            throw CodedAbort(
                status: .forbidden,
                code: "guidelines_required",
                reason: "Accept the community guidelines before posting."
            )
        }
    }
}

enum CommunityViewerKey: StorageKey {
    typealias Value = CommunityViewer
}

extension Request {
    var communityViewer: CommunityViewer {
        get throws {
            guard let viewer = storage[CommunityViewerKey.self] else {
                throw Abort(.internalServerError, reason: "Community viewer not resolved")
            }
            return viewer
        }
    }
}

enum CommunityAccess {
    /// The sanction in force, if any. A ban outranks a mute.
    static func activeSanction(for userId: UUID, on db: any Database, now: Date = Date()) async throws -> CommunitySanction? {
        let rows = try await CommunitySanction.query(on: db)
            .filter(\.$userId == userId)
            .filter(\.$revokedAt == nil)
            .all()
            .filter { $0.isActive(at: now) }
        return rows.first { $0.kind == CommunitySanctionKind.ban.rawValue } ?? rows.first
    }

    static func viewer(for userId: UUID, on db: any Database) async throws -> CommunityViewer {
        guard let user = try await User.find(userId, on: db) else {
            throw Abort(.unauthorized)
        }
        let accepted = try await CommunityGuidelinesAcceptance.query(on: db)
            .filter(\.$userId == userId)
            .first() != nil
        let suspendedAt = try await SocialSettingsRecord.query(on: db)
            .filter(\.$userId == userId)
            .first()?
            .suspendedAt
        return try await CommunityViewer(
            userId: userId,
            username: user.username,
            isAdmin: AdminGuard.isAdmin(user),
            activeSanction: activeSanction(for: userId, on: db),
            guidelinesAccepted: accepted,
            socialSuspendedAt: suspendedAt
        )
    }
}

/// Resolves the viewer and turns banned users away from every board route
/// except `/community/me`, which has to answer so the app can explain why.
struct CommunityAccessMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let session = try request.auth.require(SessionToken.self)
        let viewer = try await CommunityAccess.viewer(for: session.userId, on: request.db)
        request.storage[CommunityViewerKey.self] = viewer
        let isStatusRoute = request.url.path.hasSuffix("/community/me")
        if viewer.isBanned, !isStatusRoute {
            throw CodedAbort(
                status: .forbidden,
                code: "community_banned",
                reason: "Your access to Norviq Boards has been removed."
            )
        }
        return try await next.respond(to: request)
    }
}
