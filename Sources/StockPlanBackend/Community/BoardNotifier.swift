import Fluent
import FluentSQL
import Foundation
import StockPlanShared
import Vapor

final class BoardNotificationRecord: Model, @unchecked Sendable {
    static let schema = "board_notifications"

    @ID(key: .id) var id: UUID?
    @Field(key: "recipient_id") var recipientId: UUID
    @Field(key: "kind") var kind: String
    @OptionalField(key: "actor_id") var actorId: UUID?
    @Field(key: "post_id") var postId: UUID
    @OptionalField(key: "comment_id") var commentId: UUID?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "read_at") var readAt: Date?

    init() {}
}

final class BoardNotificationSettingsRecord: Model, @unchecked Sendable {
    static let schema = "board_notification_settings"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "reply_push") var replyPush: Bool
    @Field(key: "upvote_push") var upvotePush: Bool
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(userId: UUID, settings: BoardNotificationSettings) {
        self.userId = userId
        replyPush = settings.replyPush
        upvotePush = settings.upvotePush
    }

    var dto: BoardNotificationSettings {
        BoardNotificationSettings(replyPush: replyPush, upvotePush: upvotePush)
    }
}

/// Writes the Boards activity feed and sends the matching push. Best effort
/// throughout: a failure here is logged and never fails the vote or comment
/// that caused it.
enum BoardNotifier {
    /// Upvote pushes for the same post are held to one an hour; the feed still
    /// records every voter.
    static let upvotePushWindow: TimeInterval = 3600

    static func settings(for userId: UUID, on db: any Database) async throws -> BoardNotificationSettings {
        try await BoardNotificationSettingsRecord.query(on: db)
            .filter(\.$userId == userId)
            .first()?
            .dto ?? .default
    }

    /// Tells the parent comment's author, or the post's author for a top-level
    /// comment. Nobody is told about their own reply, or by someone either side
    /// has blocked.
    static func replied(
        comment: BoardCommentRecord,
        parent: BoardCommentRecord?,
        post: BoardPost,
        board: Board,
        actor: CommunityViewer,
        on req: Request
    ) async {
        let recipient = parent?.authorId ?? post.authorId
        guard recipient != actor.userId else { return }
        do {
            if try await SocialService.isBlockedEitherWay(recipient, actor.userId, on: req.db) {
                return
            }
            let record = BoardNotificationRecord()
            record.recipientId = recipient
            record.kind = BoardNotificationKind.reply.rawValue
            record.actorId = actor.userId
            record.postId = try post.requireID()
            record.commentId = try comment.requireID()
            try await record.create(on: req.db)

            guard try await settings(for: recipient, on: req.db).replyPush else { return }
            let who = actor.username.map { "@\($0)" } ?? "Someone"
            let title = parent == nil ? "\(who) commented on your post" : "\(who) replied to you"
            await push(
                BoardPushMessage(
                    kind: .reply,
                    title: title,
                    body: String(comment.body.prefix(140)),
                    postId: record.postId,
                    boardSlug: board.slug
                ),
                to: recipient,
                on: req
            )
        } catch {
            req.logger.warning("boards.notify reply failed error=\(String(reflecting: type(of: error)))")
        }
    }

    /// Records the first upvote from each voter; toggling off and on again
    /// does not notify twice.
    static func upvoted(post: BoardPost, board: Board, actor: CommunityViewer, on req: Request) async {
        guard post.authorId != actor.userId, let sql = req.db as? any SQLDatabase else { return }
        do {
            if try await SocialService.isBlockedEitherWay(post.authorId, actor.userId, on: req.db) {
                return
            }
            let postId = try post.requireID()
            let now = Date()
            let inserted = try await sql.raw("""
            INSERT INTO board_notifications (id, recipient_id, kind, actor_id, post_id, created_at)
            VALUES (\(bind: UUID()), \(bind: post.authorId), \(bind: BoardNotificationKind.upvote.rawValue),
                    \(bind: actor.userId), \(bind: postId), \(bind: now))
            ON CONFLICT (post_id, actor_id) WHERE kind = 'upvote' DO NOTHING
            RETURNING id
            """).all()
            guard !inserted.isEmpty, try await settings(for: post.authorId, on: req.db).upvotePush else { return }

            let recent = try await BoardNotificationRecord.query(on: req.db)
                .filter(\.$recipientId == post.authorId)
                .filter(\.$postId == postId)
                .filter(\.$kind == BoardNotificationKind.upvote.rawValue)
                .filter(\.$createdAt > now.addingTimeInterval(-upvotePushWindow))
                .count()
            // The row just written is one of them.
            guard recent <= 1 else { return }

            let who = actor.username.map { "@\($0)" } ?? "Someone"
            await push(
                BoardPushMessage(
                    kind: .upvote,
                    title: "\(who) upvoted your post",
                    body: String(post.title.prefix(140)),
                    postId: postId,
                    boardSlug: board.slug
                ),
                to: post.authorId,
                on: req
            )
        } catch {
            req.logger.warning("boards.notify upvote failed error=\(String(reflecting: type(of: error)))")
        }
    }

    private static func push(_ message: BoardPushMessage, to recipient: UUID, on req: Request) async {
        do {
            let devices = try await req.pushDeviceService.activeDevices(userId: recipient, on: req.db)
            guard !devices.isEmpty else { return }
            _ = await req.application.pushNotificationSender.sendBoardEvent(message: message, devices: devices, req: req)
        } catch {
            req.logger.warning("boards.push failed kind=\(message.kind.rawValue) error=\(String(reflecting: type(of: error)))")
        }
    }

    // MARK: - Feed

    /// Newest first. Notifications whose post is gone, or whose actor is
    /// blocked either way, are left out.
    static func page(for viewer: UUID, cursor rawCursor: String?, on db: any Database) async throws -> BoardNotificationPage {
        let pageSize = 30
        let hidden = try await SocialService.blockedEitherWay(for: viewer, on: db)
        var query = BoardNotificationRecord.query(on: db)
            .filter(\.$recipientId == viewer)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
            .limit(pageSize + 1)
        if !hidden.isEmpty {
            query = query.group(.or) { group in
                group.filter(\.$actorId == nil).filter(\.$actorId !~ Array(hidden))
            }
        }
        if let cursor = NotificationListCursor.parse(rawCursor), let id = cursor.id {
            query = query.group(.or) { group in
                group.filter(\.$createdAt < cursor.createdAt)
                    .group(.and) { tie in tie.filter(\.$createdAt == cursor.createdAt).filter(\.$id < id) }
            }
        }
        let rows = try await query.all()
        let pageRows = Array(rows.prefix(pageSize))

        let posts = try await BoardPost.query(on: db).filter(\.$id ~~ pageRows.map(\.postId)).all()
        let postById = Dictionary(posts.compactMap { p in p.id.map { ($0, p) } }, uniquingKeysWith: { a, _ in a })
        let boards = try await Board.query(on: db).filter(\.$id ~~ posts.map(\.boardId)).all()
        let slugById = Dictionary(boards.compactMap { b in b.id.map { ($0, b.slug) } }, uniquingKeysWith: { a, _ in a })
        let commentIds = pageRows.compactMap(\.commentId)
        let comments = commentIds.isEmpty ? [] : try await BoardCommentRecord.query(on: db).filter(\.$id ~~ commentIds).all()
        let commentById = Dictionary(comments.compactMap { c in c.id.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
        let names = try await BoardsService.usernames(for: pageRows.compactMap(\.actorId), on: db)

        let items = pageRows.compactMap { row -> BoardNotification? in
            // Deleted posts and boards drop out of the feed.
            guard let id = row.id, let post = postById[row.postId], let slug = slugById[post.boardId] else { return nil }
            let comment = row.commentId.flatMap { commentById[$0] }
            return BoardNotification(
                id: id,
                kind: BoardNotificationKind(rawValue: row.kind) ?? .other,
                actorUsername: row.actorId.flatMap { names[$0] },
                postId: row.postId,
                boardSlug: slug,
                postTitle: post.title,
                commentId: comment?.id,
                excerpt: comment.map { String($0.body.prefix(140)) },
                createdAt: row.createdAt ?? Date(),
                isRead: row.readAt != nil
            )
        }
        let next = rows.count > pageSize
            ? pageRows.last.flatMap { row in row.id.map { NotificationListCursor.encode(createdAt: row.createdAt ?? Date(), id: $0) } }
            : nil
        return try await BoardNotificationPage(items: items, nextCursor: next, unreadCount: unreadCount(for: viewer, on: db))
    }

    static func unreadCount(for viewer: UUID, on db: any Database) async throws -> Int {
        try await BoardNotificationRecord.query(on: db)
            .filter(\.$recipientId == viewer)
            .filter(\.$readAt == nil)
            .count()
    }

    static func markRead(_ ids: [UUID]?, for viewer: UUID, on db: any Database) async throws {
        var query = BoardNotificationRecord.query(on: db)
            .filter(\.$recipientId == viewer)
            .filter(\.$readAt == nil)
        if let ids {
            guard !ids.isEmpty else { return }
            query = query.filter(\.$id ~~ ids)
        }
        try await query.set(\.$readAt, to: Date()).update()
    }
}
