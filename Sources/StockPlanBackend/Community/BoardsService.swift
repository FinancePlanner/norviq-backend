import Fluent
import FluentSQL
import Foundation
import StockPlanShared
import Vapor

enum BoardsService {
    static let pageSize = 30
    static let maxCommentsPerPost = 500

    // MARK: - Lookups

    static func board(slug: String, on db: any Database) async throws -> Board {
        guard let board = try await Board.query(on: db)
            .filter(\.$slug == slug.lowercased())
            .first()
        else {
            throw Abort(.notFound, reason: "Board not found")
        }
        return board
    }

    /// A post whose board is gone is gone too.
    static func post(id: UUID, on db: any Database) async throws -> (BoardPost, Board) {
        guard let post = try await BoardPost.find(id, on: db),
              let board = try await Board.find(post.boardId, on: db)
        else {
            throw Abort(.notFound, reason: "Post not found")
        }
        return (post, board)
    }

    static func usernames(for ids: some Sequence<UUID>, on db: any Database) async throws -> [UUID: String] {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [:] }
        let users = try await User.query(on: db).filter(\.$id ~~ unique).all()
        var result: [UUID: String] = [:]
        for user in users {
            if let id = user.id, let username = user.username {
                result[id] = username
            }
        }
        return result
    }

    static func userId(forUsername raw: String, on db: any Database) async throws -> UUID {
        let username = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !username.isEmpty,
              let user = try await User.query(on: db).filter(\.$username == username).first(),
              let id = user.id
        else {
            throw Abort(.notFound, reason: "User not found")
        }
        return id
    }

    // MARK: - DTOs

    static func dto(_ board: Board, usernames: [UUID: String]) throws -> BoardSummary {
        try BoardSummary(
            id: board.requireID(),
            slug: board.slug,
            name: board.name,
            description: board.description,
            creatorUsername: board.creatorId.flatMap { usernames[$0] },
            postCount: board.postCount,
            createdAt: board.createdAt ?? board.lastActivityAt,
            lastActivityAt: board.lastActivityAt
        )
    }

    static func boardDTOs(_ boards: [Board], on db: any Database) async throws -> [BoardSummary] {
        let names = try await usernames(for: boards.compactMap(\.creatorId), on: db)
        return try boards.map { try dto($0, usernames: names) }
    }

    /// Summaries in the order given, with the viewer's vote and "N new" state.
    static func summaries(
        _ posts: [BoardPost],
        boardSlugs: [UUID: String],
        viewer: UUID,
        on db: any Database
    ) async throws -> [BoardPostSummary] {
        let ids = try posts.map { try $0.requireID() }
        guard !ids.isEmpty else { return [] }
        let voted = try await Set(
            BoardVote.query(on: db)
                .filter(\.$userId == viewer)
                .filter(\.$postId ~~ ids)
                .all()
                .map(\.postId)
        )
        let views = try await BoardPostView.query(on: db)
            .filter(\.$userId == viewer)
            .filter(\.$postId ~~ ids)
            .all()
        let lastSeen = Dictionary(views.map { ($0.postId, $0.lastSeenCommentCount) }, uniquingKeysWith: { first, _ in first })
        let names = try await usernames(for: posts.map(\.authorId), on: db)
        return try posts.map { post in
            let id = try post.requireID()
            return summary(
                post,
                boardSlug: boardSlugs[post.boardId] ?? "",
                authorUsername: names[post.authorId],
                viewerHasVoted: voted.contains(id),
                newCommentCount: lastSeen[id].map { max(0, post.commentCount - $0) }
            )
        }
    }

    static func summary(
        _ post: BoardPost,
        boardSlug: String,
        authorUsername: String?,
        viewerHasVoted: Bool,
        newCommentCount: Int?
    ) -> BoardPostSummary {
        BoardPostSummary(
            id: post.id ?? UUID(),
            boardSlug: boardSlug,
            kind: BoardPostKind(rawValue: post.kind) ?? .text,
            title: post.title,
            url: post.url,
            domain: post.domain,
            tags: post.tags,
            authorUsername: authorUsername,
            createdAt: post.createdAt ?? post.lastActivityAt,
            score: post.score,
            commentCount: post.commentCount,
            participantCount: post.participantCount,
            viewCount: post.viewCount,
            viewerHasVoted: viewerHasVoted,
            newCommentCount: newCommentCount
        )
    }

    // MARK: - Listing

    static func listBoards(cursor rawCursor: String?, on db: any Database) async throws -> BoardListResponse {
        var query = Board.query(on: db)
            .sort(\.$lastActivityAt, .descending)
            .sort(\.$id, .descending)
            .limit(pageSize + 1)
        if let cursor = NotificationListCursor.parse(rawCursor), let id = cursor.id {
            query = query.group(.or) { group in
                group.filter(\.$lastActivityAt < cursor.createdAt)
                    .group(.and) { tie in
                        tie.filter(\.$lastActivityAt == cursor.createdAt).filter(\.$id < id)
                    }
            }
        }
        let rows = try await query.all()
        let page = Array(rows.prefix(pageSize))
        let next = rows.count > pageSize
            ? try page.last.map { try NotificationListCursor.encode(createdAt: $0.lastActivityAt, id: $0.requireID()) }
            : nil
        return try await BoardListResponse(items: boardDTOs(page, on: db), nextCursor: next)
    }

    /// `new` and `active` page by keyset on their timestamp; `top` ranks by
    /// HN-style gravity, which shifts with time, so it pages by offset.
    static func listPosts(
        board: Board,
        sort: BoardPostSort,
        kind: BoardPostKind?,
        tag: String?,
        cursor rawCursor: String?,
        viewer: UUID,
        on db: any Database
    ) async throws -> BoardPostPage {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Boards need a SQL database")
        }
        let boardId = try board.requireID()
        let hidden = try await SocialService.blockedEitherWay(for: viewer, on: db)

        var query = sql.select()
            .column("id")
            .from(BoardPost.schema)
            .where("board_id", .equal, SQLBind(boardId))
            .where("deleted_at", .is, SQLLiteral.null)
        if let kind {
            query = query.where("kind", .equal, SQLBind(kind.rawValue))
        }
        if let tag {
            query = query.where(SQLBinaryExpression(SQLBind(tag), .equal, SQLFunction("ANY", args: SQLColumn("tags"))))
        }
        if !hidden.isEmpty {
            query = query.where("author_id", .notIn, SQLBind.group(Array(hidden)))
        }

        var offset = 0
        switch sort {
        case .new, .active:
            let column = sort == .new ? "created_at" : "last_activity_at"
            if let cursor = NotificationListCursor.parse(rawCursor), let id = cursor.id {
                query = query.where(
                    SQLBinaryExpression(
                        SQLGroupExpression([SQLColumn(column), SQLColumn("id")]),
                        .lessThan,
                        SQLGroupExpression([SQLBind(cursor.createdAt), SQLBind(id)])
                    )
                )
            }
            query = query.orderBy(column, .descending).orderBy("id", .descending)
        case .top:
            offset = rawCursor.flatMap(Self.topOffset) ?? 0
            query = query
                .orderBy(SQLOrderBy(
                    expression: SQLRaw("(score + 1) / power(extract(epoch from (now() - created_at)) / 3600.0 + 2, 1.5)"),
                    direction: SQLDirection.descending
                ))
                .orderBy("created_at", .descending)
                .orderBy("id", .descending)
                .offset(offset)
        }

        let rows = try await query.limit(pageSize + 1).all()
        let orderedIds = try rows.map { try $0.decode(column: "id", as: UUID.self) }
        let pageIds = Array(orderedIds.prefix(pageSize))
        let byId = try await Dictionary(
            BoardPost.query(on: db).filter(\.$id ~~ pageIds).all().map { try ($0.requireID(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let posts = pageIds.compactMap { byId[$0] }

        var next: String?
        if orderedIds.count > pageSize, let last = posts.last {
            switch sort {
            case .new:
                next = try NotificationListCursor.encode(createdAt: last.createdAt ?? last.lastActivityAt, id: last.requireID())
            case .active:
                next = try NotificationListCursor.encode(createdAt: last.lastActivityAt, id: last.requireID())
            case .top:
                next = "top-\(offset + pageSize)"
            }
        }

        let items = try await summaries(posts, boardSlugs: [boardId: board.slug], viewer: viewer, on: db)
        return BoardPostPage(items: items, nextCursor: next)
    }

    static func topOffset(_ cursor: String) -> Int? {
        guard cursor.hasPrefix("top-"), let value = Int(cursor.dropFirst(4)), value >= 0 else { return nil }
        return value
    }

    // MARK: - Detail

    /// Records the view, then returns the post with every comment. Comments by
    /// people blocked either way, and deleted ones, keep their slot with no
    /// body so the thread still hangs together.
    static func detail(postId: UUID, viewer: UUID, on db: any Database) async throws -> BoardPostDetail {
        let (post, board) = try await post(id: postId, on: db)
        let hidden = try await SocialService.blockedEitherWay(for: viewer, on: db)
        guard !hidden.contains(post.authorId) else {
            throw Abort(.notFound, reason: "Post not found")
        }

        let previous = try await recordView(post: post, viewer: viewer, on: db)
        // `recordView` may have bumped the count; reload so the response matches.
        let fresh = try await BoardPost.find(postId, on: db) ?? post

        let comments = try await BoardCommentRecord.query(on: db)
            .withDeleted()
            .filter(\.$postId == postId)
            .sort(\.$createdAt, .ascending)
            .limit(maxCommentsPerPost)
            .all()
        let names = try await usernames(for: comments.map(\.authorId) + [post.authorId], on: db)
        let commentDTOs = try comments.map { comment in
            let gone = comment.deletedAt != nil || hidden.contains(comment.authorId)
            return try BoardComment(
                id: comment.requireID(),
                parentId: comment.parentId,
                depth: comment.depth,
                authorUsername: gone ? nil : names[comment.authorId],
                body: gone ? "" : comment.body,
                createdAt: comment.createdAt ?? Date(),
                isDeleted: gone
            )
        }

        let voted = try await BoardVote.query(on: db)
            .filter(\.$postId == postId)
            .filter(\.$userId == viewer)
            .first() != nil
        let summary = summary(
            fresh,
            boardSlug: board.slug,
            authorUsername: names[post.authorId],
            viewerHasVoted: voted,
            newCommentCount: previous.map { max(0, fresh.commentCount - $0) }
        )
        return BoardPostDetail(post: summary, body: fresh.body, comments: commentDTOs)
    }

    /// Returns the comment count the viewer saw last time, or nil on a first
    /// visit (which is also the only time the view count moves).
    @discardableResult
    static func recordView(post: BoardPost, viewer: UUID, on db: any Database) async throws -> Int? {
        let postId = try post.requireID()
        guard let sql = db as? any SQLDatabase else { return nil }
        let existing = try await BoardPostView.query(on: db)
            .filter(\.$postId == postId)
            .filter(\.$userId == viewer)
            .first()
        if let existing {
            let previous = existing.lastSeenCommentCount
            existing.lastSeenCommentCount = post.commentCount
            existing.lastSeenAt = Date()
            try await existing.save(on: db)
            return previous
        }
        let inserted = try await sql.raw("""
        INSERT INTO board_post_views (id, post_id, user_id, last_seen_comment_count, last_seen_at)
        VALUES (\(bind: UUID()), \(bind: postId), \(bind: viewer), \(bind: post.commentCount), \(bind: Date()))
        ON CONFLICT (post_id, user_id) DO NOTHING
        RETURNING id
        """).all()
        if !inserted.isEmpty {
            try await sql.raw("UPDATE board_posts SET view_count = view_count + 1 WHERE id = \(bind: postId)").run()
        }
        return nil
    }
}
