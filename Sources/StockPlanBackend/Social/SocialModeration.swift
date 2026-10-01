import Fluent
import Foundation
import Vapor

/// Review queue for social reports (App Review Guideline 1.2): every report
/// pings the team's Discord, and moderators resolve reports and suspend users
/// through `/v1/admin/social`. Moderators are the emails listed in
/// `SOCIAL_MODERATOR_EMAILS`; with none configured the admin routes stay shut.
enum SocialModeration {
    static func notifyNewReport(
        targetType: SocialReportTargetType,
        targetId: String,
        reason: SocialReportReason,
        on req: Request
    ) async {
        do {
            let open = try await SocialReport.query(on: req.db).filter(\.$status == "open").count()
            var target = targetId
            if targetType == .user, let id = UUID(uuidString: targetId),
               let username = try await User.find(id, on: req.db)?.username
            {
                target = "@\(username) (\(targetId))"
            }
            try await req.discord.send(
                "🚩 New social report: \(reason.rawValue) on \(targetType.rawValue) \(target). " +
                    "\(open) open. Review within 24 hours: GET /v1/admin/social/reports",
                on: req
            )
        } catch {
            req.logger.warning("social.report notify failed error=\(String(reflecting: type(of: error)))")
        }
    }

    static func moderatorEmails() -> Set<String> {
        Set(
            (Environment.get("SOCIAL_MODERATOR_EMAILS") ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
    }
}

struct SocialModerationReportDTO: Content, Equatable {
    let id: UUID
    let reporterId: UUID
    let targetType: String
    let targetId: String
    let targetUsername: String?
    let reason: String
    let note: String?
    let status: String
    let resolution: String?
    let resolutionNote: String?
    let createdAt: Date?
    let resolvedAt: Date?
}

struct SocialModerationReportsResponse: Content, Equatable {
    let reports: [SocialModerationReportDTO]
}

enum SocialModerationAction: String, Codable, Sendable {
    /// Nothing wrong; close the report.
    case dismiss
    /// Suspend the reported user from social and close the report.
    case suspendUser = "suspend_user"
}

struct SocialModerationResolveBody: Content {
    let action: SocialModerationAction
    let note: String?
}

struct SocialModerationController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let admin = routes.grouped("admin", "social")
            .grouped(SessionToken.authenticator(), SessionToken.guardMiddleware(), SocialModeratorMiddleware())
        admin.get("reports", use: reports)
        admin.post("reports", ":reportId", "resolve", use: resolve)
        admin.post("users", ":userId", "suspend", use: suspend)
        admin.delete("users", ":userId", "suspend", use: unsuspend)
    }

    /// `?status=open` (default) or `?status=all`, oldest first so the queue
    /// is worked in order.
    @Sendable
    func reports(req: Request) async throws -> SocialModerationReportsResponse {
        let status = (try? req.query.get(String.self, at: "status")) ?? "open"
        var query = SocialReport.query(on: req.db).sort(\.$createdAt, .ascending).limit(200)
        if status != "all" {
            query = query.filter(\.$status == "open")
        }
        let rows = try await query.all()
        let userIds = rows.compactMap { $0.targetType == SocialReportTargetType.user.rawValue ? UUID(uuidString: $0.targetId) : nil }
        let users = userIds.isEmpty ? [] : try await User.query(on: req.db).filter(\.$id ~~ userIds).all()
        let names = Dictionary(users.compactMap { user in user.id.map { ($0, user.username) } }, uniquingKeysWith: { first, _ in first })
        let dtos = rows.compactMap { row -> SocialModerationReportDTO? in
            guard let id = row.id else { return nil }
            let username: String? = UUID(uuidString: row.targetId).flatMap { names[$0].flatMap(\.self) }
            return SocialModerationReportDTO(
                id: id,
                reporterId: row.reporterId,
                targetType: row.targetType,
                targetId: row.targetId,
                targetUsername: username,
                reason: row.reason,
                note: row.note,
                status: row.status,
                resolution: row.resolution,
                resolutionNote: row.resolutionNote,
                createdAt: row.createdAt,
                resolvedAt: row.resolvedAt
            )
        }
        return SocialModerationReportsResponse(reports: dtos)
    }

    @Sendable
    func resolve(req: Request) async throws -> HTTPStatus {
        let moderator = try req.auth.require(SessionToken.self).userId
        guard let reportId = req.parameters.get("reportId", as: UUID.self),
              let report = try await SocialReport.find(reportId, on: req.db)
        else {
            throw Abort(.notFound, reason: "Report not found")
        }
        let body = try req.content.decode(SocialModerationResolveBody.self)
        if body.action == .suspendUser {
            guard report.targetType == SocialReportTargetType.user.rawValue,
                  let target = UUID(uuidString: report.targetId)
            else {
                throw Abort(.unprocessableEntity, reason: "Only user reports can suspend a user.")
            }
            try await Self.setSuspended(target, suspended: true, on: req.db)
        }
        report.status = "resolved"
        report.resolution = body.action.rawValue
        report.resolutionNote = body.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        report.resolvedBy = moderator
        report.resolvedAt = Date()
        try await report.save(on: req.db)
        req.logger.notice("social.report resolved action=\(body.action.rawValue)")
        return .noContent
    }

    @Sendable
    func suspend(req: Request) async throws -> HTTPStatus {
        try await Self.setSuspended(Self.userParameter(req), suspended: true, on: req.db)
        return .noContent
    }

    @Sendable
    func unsuspend(req: Request) async throws -> HTTPStatus {
        try await Self.setSuspended(Self.userParameter(req), suspended: false, on: req.db)
        return .noContent
    }

    static func userParameter(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("userId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid userId")
        }
        return id
    }

    /// Suspending also ends the user's friendships and pending requests, so
    /// lifting a suspension doesn't silently restore contact.
    static func setSuspended(_ userId: UUID, suspended: Bool, on db: any Database) async throws {
        guard try await User.find(userId, on: db) != nil else {
            throw Abort(.notFound, reason: "User not found")
        }
        try await db.transaction { tx in
            let record = try await SocialSettingsRecord.query(on: tx).filter(\.$userId == userId).first()
                ?? SocialSettingsRecord(userId: userId)
            record.suspendedAt = suspended ? (record.suspendedAt ?? Date()) : nil
            try await record.save(on: tx)
            if suspended {
                try await SocialFriendship.query(on: tx)
                    .group(.or) { $0.filter(\.$userId == userId).filter(\.$friendId == userId) }
                    .delete()
                try await SocialFriendRequest.query(on: tx)
                    .group(.or) { $0.filter(\.$fromUserId == userId).filter(\.$toUserId == userId) }
                    .delete()
            }
        }
    }
}

/// Fail-closed: denies everyone unless the caller's email is listed in
/// `SOCIAL_MODERATOR_EMAILS`.
struct SocialModeratorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let moderators = SocialModeration.moderatorEmails()
        guard !moderators.isEmpty else {
            throw Abort(.forbidden, reason: "Social moderation is disabled (SOCIAL_MODERATOR_EMAILS is not set).")
        }
        let userId = try request.auth.require(SessionToken.self).userId
        guard let user = try await User.find(userId, on: request.db),
              moderators.contains(user.email.lowercased())
        else {
            throw Abort(.forbidden, reason: "Moderator access required.")
        }
        return try await next.respond(to: request)
    }
}
