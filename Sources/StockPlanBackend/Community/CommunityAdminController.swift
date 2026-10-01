import Fluent
import Foundation
import StockPlanShared
import Vapor

/// `/v1/admin`: board deletion, mutes and bans, and the board report queue.
/// Everything here sits behind the `AdminGuard` email allowlist.
struct CommunityAdminController: RouteCollection {
    static let maxSanctionHours = 24 * 365

    func boot(routes: any RoutesBuilder) throws {
        let admin = routes.grouped("admin")
            .grouped(ScopedBearerAuthenticator(), SessionToken.guardMiddleware(), FirstPartyOnlyMiddleware())
            .grouped(AdminOnlyMiddleware())

        admin.delete("boards", ":slug", use: deleteBoard)

        let community = admin.grouped("community")
        community.get("sanctions", use: listSanctions)
        community.post("sanctions", use: createSanction)
        community.delete("sanctions", ":sanctionId", use: revokeSanction)
        community.get("reports", use: listReports)
        community.post("reports", ":reportId", "resolve", use: resolveReport)
    }

    /// Soft delete: the board and its posts disappear, the slug stays taken.
    @Sendable
    func deleteBoard(req: Request) async throws -> HTTPStatus {
        let board = try await BoardsService.board(slug: req.parameters.get("slug") ?? "", on: req.db)
        try await board.delete(on: req.db)
        req.logger.notice("boards.admin deleted board slug=\(board.slug)")
        return .noContent
    }

    @Sendable
    func listSanctions(req: Request) async throws -> UserSanctionListResponse {
        let rows = try await CommunitySanction.query(on: req.db)
            .sort(\.$createdAt, .descending)
            .limit(200)
            .all()
        let names = try await BoardsService.usernames(for: rows.map(\.userId), on: req.db)
        return try UserSanctionListResponse(items: rows.map { try Self.dto($0, username: names[$0.userId]) })
    }

    /// A new sanction of the same kind replaces the one in force, so changing
    /// a mute's length is just issuing it again.
    @Sendable
    func createSanction(req: Request) async throws -> UserSanction {
        let admin = try req.auth.require(SessionToken.self).userId
        let body = try req.content.decode(CreateSanctionRequest.self)
        let target = try await BoardsService.userId(forUsername: body.username, on: req.db)
        guard let targetUser = try await User.find(target, on: req.db), !AdminGuard.isAdmin(targetUser) else {
            throw Abort(.badRequest, reason: "Admins can't be muted or banned.")
        }
        let reason = body.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty, reason.count <= 500 else {
            throw Abort(.badRequest, reason: "Give a reason of up to 500 characters.")
        }
        if let hours = body.durationHours, !(1 ... Self.maxSanctionHours).contains(hours) {
            throw Abort(.badRequest, reason: "Duration must be between 1 hour and a year, or empty for indefinite.")
        }

        let now = Date()
        let sanction = CommunitySanction(
            userId: target,
            kind: body.kind.rawValue,
            reason: reason,
            expiresAt: body.durationHours.map { now.addingTimeInterval(Double($0) * 3600) },
            createdBy: admin
        )
        try await req.db.transaction { tx in
            try await CommunitySanction.query(on: tx)
                .filter(\.$userId == target)
                .filter(\.$kind == body.kind.rawValue)
                .filter(\.$revokedAt == nil)
                .set(\.$revokedAt, to: now)
                .update()
            try await sanction.create(on: tx)
        }
        req.logger.notice("boards.admin sanction kind=\(body.kind.rawValue) hours=\(body.durationHours.map(String.init) ?? "indefinite")")
        return try Self.dto(sanction, username: targetUser.username)
    }

    @Sendable
    func revokeSanction(req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("sanctionId", as: UUID.self),
              let sanction = try await CommunitySanction.find(id, on: req.db)
        else {
            throw Abort(.notFound, reason: "Sanction not found")
        }
        if sanction.revokedAt == nil {
            sanction.revokedAt = Date()
            try await sanction.save(on: req.db)
        }
        return .noContent
    }

    @Sendable
    func listReports(req: Request) async throws -> BoardReportListResponse {
        let reports = try await SocialReport.query(on: req.db)
            .filter(\.$targetType ~~ [CommunityReportTarget.post, CommunityReportTarget.comment])
            .filter(\.$status == "open")
            .sort(\.$createdAt, .descending)
            .limit(200)
            .all()
        let ids = reports.compactMap { UUID(uuidString: $0.targetId) }
        // Reported content may already be deleted; the queue still shows it.
        let comments = try await BoardCommentRecord.query(on: req.db).withDeleted().filter(\.$id ~~ ids).all()
        let postIds = ids + comments.map(\.postId)
        let posts = try await BoardPost.query(on: req.db).withDeleted().filter(\.$id ~~ postIds).all()
        let boards = try await Board.query(on: req.db).withDeleted().filter(\.$id ~~ posts.map(\.boardId)).all()

        let commentById = Dictionary(comments.compactMap { c in c.id.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
        let postById = Dictionary(posts.compactMap { p in p.id.map { ($0, p) } }, uniquingKeysWith: { a, _ in a })
        let slugById = Dictionary(boards.compactMap { b in b.id.map { ($0, b.slug) } }, uniquingKeysWith: { a, _ in a })
        let names = try await BoardsService.usernames(
            for: reports.map(\.reporterId) + posts.map(\.authorId) + comments.map(\.authorId),
            on: req.db
        )

        let items = try reports.map { report -> BoardReportItem in
            let targetId = UUID(uuidString: report.targetId)
            let isComment = report.targetType == CommunityReportTarget.comment
            let comment = isComment ? targetId.flatMap { commentById[$0] } : nil
            let post = isComment ? comment.flatMap { postById[$0.postId] } : targetId.flatMap { postById[$0] }
            let authorId = comment?.authorId ?? post?.authorId
            return try BoardReportItem(
                id: report.requireID(),
                reporterUsername: names[report.reporterId],
                postId: post?.id,
                commentId: comment?.id,
                boardSlug: post.flatMap { slugById[$0.boardId] },
                excerpt: String((comment?.body ?? post?.title ?? "(gone)").prefix(280)),
                targetAuthorUsername: authorId.flatMap { names[$0] },
                reason: BoardReportReason(rawValue: report.reason) ?? .other,
                note: report.note,
                createdAt: report.createdAt ?? Date()
            )
        }
        return BoardReportListResponse(items: items)
    }

    @Sendable
    func resolveReport(req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("reportId", as: UUID.self),
              let report = try await SocialReport.find(id, on: req.db)
        else {
            throw Abort(.notFound, reason: "Report not found")
        }
        // Same fields the social moderation queue writes, so a board report
        // closed here reads as closed there too.
        report.status = "resolved"
        report.resolution = "dismiss"
        report.resolvedBy = try req.auth.require(SessionToken.self).userId
        report.resolvedAt = Date()
        try await report.save(on: req.db)
        return .noContent
    }

    // MARK: - Mapping

    static func dto(_ sanction: CommunitySanction, username: String?) throws -> UserSanction {
        try UserSanction(
            id: sanction.requireID(),
            username: username,
            kind: CommunitySanctionKind(rawValue: sanction.kind) ?? .mute,
            reason: sanction.reason,
            expiresAt: sanction.expiresAt,
            createdAt: sanction.createdAt ?? Date(),
            revokedAt: sanction.revokedAt
        )
    }

    static func dto(_ sanction: CommunitySanction, on db: any Database) async throws -> UserSanction {
        let username = try await User.find(sanction.userId, on: db)?.username
        return try dto(sanction, username: username)
    }
}
