import Fluent
import FluentSQL
import Foundation
import StockPlanShared
import Vapor

/// `/v1/boards`, `/v1/board-posts`, `/v1/board-comments`, `/v1/board-reports`
/// and `/v1/community`: user-created topic boards. First-party sessions only.
/// Every route resolves the viewer first so bans and mutes bite immediately,
/// whatever the token's age.
struct BoardsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let base = routes.grouped(
            ScopedBearerAuthenticator(),
            SessionToken.guardMiddleware(),
            FirstPartyOnlyMiddleware(),
            CommunityAccessMiddleware()
        )

        let community = base.grouped("community")
        community.get("me", use: viewerStatus)
        community.post("guidelines", "accept", use: acceptGuidelines)
        community.post("blocks", use: block)
        community.delete("blocks", ":username", use: unblock)

        let boards = base.grouped("boards")
        boards.get(use: listBoards)
        // The per-day cap is enforced in the handler against the database;
        // this only stops a burst.
        boards.grouped(RateLimitMiddleware(limit: 10, interval: 3600, keyPrefix: "ratelimit:board-create"))
            .post(use: createBoard)
        boards.get(":slug", use: getBoard)
        boards.patch(":slug", use: updateBoard)
        boards.get(":slug", "posts", use: listPosts)
        boards.grouped(RateLimitMiddleware(limit: 10, interval: 3600, keyPrefix: "ratelimit:board-post"))
            .post(":slug", "posts", use: createPost)

        let posts = base.grouped("board-posts")
        posts.get(":postId", use: getPost)
        posts.delete(":postId", use: deletePost)
        posts.grouped(RateLimitMiddleware(limit: 60, interval: 60, keyPrefix: "ratelimit:board-vote"))
            .post(":postId", "vote", use: vote)
        posts.grouped(RateLimitMiddleware(limit: 30, interval: 600, keyPrefix: "ratelimit:board-comment"))
            .post(":postId", "comments", use: createComment)

        base.delete("board-comments", ":commentId", use: deleteComment)
        base.grouped(RateLimitMiddleware(limit: 20, interval: 3600, keyPrefix: "ratelimit:board-report"))
            .post("board-reports", use: report)
    }

    // MARK: - Viewer

    @Sendable
    func viewerStatus(req: Request) async throws -> CommunityViewerStatus {
        let viewer = try req.communityViewer
        var sanction = try viewer.activeSanction.map { try CommunityAdminController.dto($0, username: viewer.username) }
        // A social suspension has no sanction row; report it as the ban it acts as,
        // so clients need only one rule.
        if let suspendedAt = viewer.socialSuspendedAt, !viewer.isAdmin, sanction?.kind != .ban {
            sanction = UserSanction(
                id: viewer.userId,
                username: viewer.username,
                kind: .ban,
                reason: "Suspended by a moderator.",
                expiresAt: nil,
                createdAt: suspendedAt,
                revokedAt: nil
            )
        }
        return CommunityViewerStatus(
            username: viewer.username,
            isAdmin: viewer.isAdmin,
            guidelinesAccepted: viewer.guidelinesAccepted,
            hasUsername: viewer.username?.isEmpty == false,
            activeSanction: sanction
        )
    }

    /// Idempotent.
    @Sendable
    func acceptGuidelines(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        if !viewer.guidelinesAccepted {
            try await CommunityGuidelinesAcceptance(userId: viewer.userId).create(on: req.db)
        }
        return .noContent
    }

    /// Writes the same `social_blocks` row the Friends feature uses, so a block
    /// anywhere hides the person everywhere. Idempotent.
    @Sendable
    func block(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        let body = try req.content.decode(UserBlockRequest.self)
        let target = try await BoardsService.userId(forUsername: body.username, on: req.db)
        guard target != viewer.userId else {
            throw Abort(.badRequest, reason: "You can't block yourself.")
        }
        try await req.db.transaction { tx in
            let exists = try await SocialBlock.query(on: tx)
                .filter(\.$blockerId == viewer.userId)
                .filter(\.$blockedId == target)
                .first() != nil
            if !exists {
                try await SocialBlock(blockerId: viewer.userId, blockedId: target).save(on: tx)
            }
            try await SocialService.unfriend(viewer.userId, target, on: tx)
            try await SocialService.deleteRequests(between: viewer.userId, target, on: tx)
        }
        return .noContent
    }

    @Sendable
    func unblock(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        let target = try await BoardsService.userId(forUsername: req.parameters.get("username") ?? "", on: req.db)
        try await SocialBlock.query(on: req.db)
            .filter(\.$blockerId == viewer.userId)
            .filter(\.$blockedId == target)
            .delete()
        return .noContent
    }

    // MARK: - Boards

    @Sendable
    func listBoards(req: Request) async throws -> BoardListResponse {
        try await BoardsService.listBoards(cursor: req.query[String.self, at: "cursor"], on: req.db)
    }

    @Sendable
    func createBoard(req: Request) async throws -> BoardSummary {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let body = try req.content.decode(CreateBoardRequest.self)
        let slug = try CommunityValidation.slug(body.slug)
        let name = try CommunityValidation.boardName(body.name)
        let description = try CommunityValidation.boardDescription(body.description)

        if !viewer.isAdmin {
            // Deleted boards still count, or deleting would refill the quota.
            let recent = try await Board.query(on: req.db)
                .withDeleted()
                .filter(\.$creatorId == viewer.userId)
                .filter(\.$createdAt > Date().addingTimeInterval(-86400))
                .count()
            guard recent < CommunityValidation.maxBoardsPerDay else {
                throw CodedAbort(
                    status: .tooManyRequests,
                    code: "board_limit_reached",
                    reason: "You can create up to \(CommunityValidation.maxBoardsPerDay) boards a day."
                )
            }
        }
        let taken = try await Board.query(on: req.db).withDeleted().filter(\.$slug == slug).first() != nil
        guard !taken else {
            throw Abort(.conflict, reason: "That board address is taken.")
        }

        let board = Board(slug: slug, name: name, description: description, creatorId: viewer.userId)
        try await board.create(on: req.db)
        return try BoardsService.dto(board, usernames: viewer.username.map { [viewer.userId: $0] } ?? [:])
    }

    @Sendable
    func getBoard(req: Request) async throws -> BoardSummary {
        let board = try await BoardsService.board(slug: req.parameters.get("slug") ?? "", on: req.db)
        return try await BoardsService.boardDTOs([board], on: req.db)[0]
    }

    @Sendable
    func updateBoard(req: Request) async throws -> BoardSummary {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let board = try await BoardsService.board(slug: req.parameters.get("slug") ?? "", on: req.db)
        guard board.creatorId == viewer.userId || viewer.isAdmin else {
            throw Abort(.forbidden, reason: "Only the board's creator can edit it.")
        }
        board.description = try CommunityValidation.boardDescription(req.content.decode(UpdateBoardRequest.self).description)
        try await board.save(on: req.db)
        return try await BoardsService.boardDTOs([board], on: req.db)[0]
    }

    // MARK: - Posts

    @Sendable
    func listPosts(req: Request) async throws -> BoardPostPage {
        let viewer = try req.communityViewer
        let board = try await BoardsService.board(slug: req.parameters.get("slug") ?? "", on: req.db)
        let sort = req.query[String.self, at: "sort"].flatMap(BoardPostSort.init(rawValue:)) ?? .new
        let kind = req.query[String.self, at: "kind"].flatMap(BoardPostKind.init(rawValue:))
        let tag = try req.query[String.self, at: "tag"].flatMap { try CommunityValidation.tags([$0]).first }
        return try await BoardsService.listPosts(
            board: board,
            sort: sort,
            kind: kind,
            tag: tag,
            cursor: req.query[String.self, at: "cursor"],
            viewer: viewer.userId,
            on: req.db
        )
    }

    @Sendable
    func createPost(req: Request) async throws -> BoardPostSummary {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let board = try await BoardsService.board(slug: req.parameters.get("slug") ?? "", on: req.db)
        let boardId = try board.requireID()
        let body = try req.content.decode(CreateBoardPostRequest.self)

        let title = try CommunityValidation.title(body.title)
        let tags = try CommunityValidation.tags(body.tags)
        let text = try CommunityValidation.postBody(body.body)
        var url: String?
        var domain: String?
        switch body.kind {
        case .link:
            (url, domain) = try CommunityValidation.link(body.url)
        case .text, .ask, .show:
            guard (body.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty else {
                throw Abort(.badRequest, reason: "Only link posts take a URL.")
            }
        }

        let now = Date()
        let post = BoardPost(
            boardId: boardId,
            authorId: viewer.userId,
            kind: body.kind.rawValue,
            title: title,
            url: url,
            domain: domain,
            body: text,
            tags: tags,
            now: now
        )
        try await req.db.transaction { tx in
            try await post.create(on: tx)
            try await Self.sql(tx).raw("""
            UPDATE boards SET post_count = post_count + 1, last_activity_at = \(bind: now) WHERE id = \(bind: boardId)
            """).run()
        }
        return BoardsService.summary(
            post,
            boardSlug: board.slug,
            authorUsername: viewer.username,
            viewerHasVoted: false,
            newCommentCount: nil
        )
    }

    @Sendable
    func getPost(req: Request) async throws -> BoardPostDetail {
        let viewer = try req.communityViewer
        return try await BoardsService.detail(postId: Self.uuid("postId", on: req), viewer: viewer.userId, on: req.db)
    }

    @Sendable
    func deletePost(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        let (post, board) = try await BoardsService.post(id: Self.uuid("postId", on: req), on: req.db)
        guard post.authorId == viewer.userId || viewer.isAdmin else {
            throw Abort(.forbidden, reason: "You can only delete your own posts.")
        }
        let boardId = try board.requireID()
        try await req.db.transaction { tx in
            try await post.delete(on: tx)
            try await Self.sql(tx).raw("""
            UPDATE boards SET post_count = GREATEST(post_count - 1, 0) WHERE id = \(bind: boardId)
            """).run()
        }
        return .noContent
    }

    /// Toggles the viewer's upvote. The vote row and the score move in one
    /// transaction so the score is always the row count.
    @Sendable
    func vote(req: Request) async throws -> BoardVoteResponse {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let (post, _) = try await BoardsService.post(id: Self.uuid("postId", on: req), on: req.db)
        let postId = try post.requireID()
        return try await req.db.transaction { tx in
            let sql = try Self.sql(tx)
            let inserted = try await sql.raw("""
            INSERT INTO board_votes (id, post_id, user_id, created_at)
            VALUES (\(bind: UUID()), \(bind: postId), \(bind: viewer.userId), \(bind: Date()))
            ON CONFLICT (post_id, user_id) DO NOTHING
            RETURNING id
            """).all()
            let voted = !inserted.isEmpty
            if !voted {
                try await BoardVote.query(on: tx)
                    .filter(\.$postId == postId)
                    .filter(\.$userId == viewer.userId)
                    .delete()
            }
            let row = try await sql.raw("""
            UPDATE board_posts SET score = GREATEST(score + \(bind: voted ? 1 : -1), 0)
            WHERE id = \(bind: postId) RETURNING score
            """).first()
            let score = try row?.decode(column: "score", as: Int.self) ?? post.score
            return BoardVoteResponse(score: score, voted: voted)
        }
    }

    // MARK: - Comments

    @Sendable
    func createComment(req: Request) async throws -> BoardComment {
        let viewer = try req.communityViewer
        try viewer.requireCanContribute()
        let (post, board) = try await BoardsService.post(id: Self.uuid("postId", on: req), on: req.db)
        let postId = try post.requireID()
        let boardId = try board.requireID()
        let body = try req.content.decode(CreateBoardCommentRequest.self)
        let text = try CommunityValidation.commentBody(body.body)

        if try await SocialService.isBlockedEitherWay(viewer.userId, post.authorId, on: req.db) {
            throw Abort(.notFound, reason: "Post not found")
        }

        var depth = 0
        if let parentId = body.parentId {
            guard let parent = try await BoardCommentRecord.find(parentId, on: req.db), parent.postId == postId else {
                throw Abort(.badRequest, reason: "That reply target is gone.")
            }
            depth = parent.depth + 1
            guard depth <= CommunityValidation.maxCommentDepth else {
                throw Abort(.badRequest, reason: "This thread is too deep to reply further.")
            }
        }

        let comment = BoardCommentRecord(
            postId: postId,
            parentId: body.parentId,
            authorId: viewer.userId,
            body: text,
            depth: depth
        )
        let now = Date()
        try await req.db.transaction { tx in
            let isNewParticipant: Bool = if viewer.userId == post.authorId {
                false
            } else {
                try await BoardCommentRecord.query(on: tx)
                    .withDeleted()
                    .filter(\.$postId == postId)
                    .filter(\.$authorId == viewer.userId)
                    .first() == nil
            }
            try await comment.create(on: tx)
            let sql = try Self.sql(tx)
            try await sql.raw("""
            UPDATE board_posts
            SET comment_count = comment_count + 1,
                participant_count = participant_count + \(bind: isNewParticipant ? 1 : 0),
                last_activity_at = \(bind: now)
            WHERE id = \(bind: postId)
            """).run()
            try await sql.raw("UPDATE boards SET last_activity_at = \(bind: now) WHERE id = \(bind: boardId)").run()
            // Your own comment is not news to you.
            try await sql.raw("""
            UPDATE board_post_views SET last_seen_comment_count = last_seen_comment_count + 1
            WHERE post_id = \(bind: postId) AND user_id = \(bind: viewer.userId)
            """).run()
        }
        return try BoardComment(
            id: comment.requireID(),
            parentId: comment.parentId,
            depth: comment.depth,
            authorUsername: viewer.username,
            body: comment.body,
            createdAt: comment.createdAt ?? now,
            isDeleted: false
        )
    }

    /// Soft delete: the thread keeps the slot and shows it as deleted.
    @Sendable
    func deleteComment(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        guard let comment = try await BoardCommentRecord.find(Self.uuid("commentId", on: req), on: req.db) else {
            throw Abort(.notFound, reason: "Comment not found")
        }
        guard comment.authorId == viewer.userId || viewer.isAdmin else {
            throw Abort(.forbidden, reason: "You can only delete your own comments.")
        }
        try await comment.delete(on: req.db)
        return .noContent
    }

    // MARK: - Reports

    /// Lands in the same `social_reports` queue as Friends reports, with a
    /// board target type, and pings Discord so a report is seen the same day.
    @Sendable
    func report(req: Request) async throws -> HTTPStatus {
        let viewer = try req.communityViewer
        let body = try req.content.decode(BoardReportRequest.self)
        let note = body.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (note?.count ?? 0) <= 1000 else {
            throw Abort(.badRequest, reason: "Keep the details under 1,000 characters.")
        }

        let targetType: String
        let targetId: UUID
        let excerpt: String
        switch (body.postId, body.commentId) {
        case let (postId?, nil):
            guard let post = try await BoardPost.find(postId, on: req.db) else {
                throw Abort(.notFound, reason: "Post not found")
            }
            (targetType, targetId, excerpt) = (CommunityReportTarget.post, postId, post.title)
        case let (nil, commentId?):
            guard let comment = try await BoardCommentRecord.find(commentId, on: req.db) else {
                throw Abort(.notFound, reason: "Comment not found")
            }
            (targetType, targetId, excerpt) = (CommunityReportTarget.comment, commentId, comment.body)
        default:
            throw Abort(.badRequest, reason: "Report exactly one post or comment.")
        }

        try await SocialReport(
            reporterId: viewer.userId,
            targetType: targetType,
            targetId: targetId.uuidString,
            reason: body.reason.rawValue,
            note: (note?.isEmpty ?? true) ? nil : note
        ).save(on: req.db)
        req.logger.notice("boards.report filed target_type=\(targetType) reason=\(body.reason.rawValue)")

        let reason = body.reason.rawValue
        Task {
            do {
                try await req.discord.send(
                    "🚩 Board report (\(reason)) on \(targetType):\n```\(excerpt.prefix(300))```",
                    on: req
                )
            } catch {
                req.logger.debug("Failed to send discord board report notification")
            }
        }
        return .accepted
    }

    // MARK: - Helpers

    static func uuid(_ name: String, on req: Request) throws -> UUID {
        guard let value = req.parameters.get(name, as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid \(name)")
        }
        return value
    }

    static func sql(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Boards need a SQL database")
        }
        return sql
    }
}

/// `social_reports.target_type` values for board content.
enum CommunityReportTarget {
    static let post = "board_post"
    static let comment = "board_comment"
}
