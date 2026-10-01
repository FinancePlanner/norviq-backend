import Fluent
import Foundation

/// A user-created topic board. Soft-deleted by an admin; the slug stays taken
/// so nobody can reopen a removed board under the same address.
final class Board: Model, @unchecked Sendable {
    static let schema = "boards"

    @ID(key: .id) var id: UUID?
    @Field(key: "slug") var slug: String
    @Field(key: "name") var name: String
    @Field(key: "description") var description: String
    @OptionalField(key: "creator_id") var creatorId: UUID?
    @Field(key: "post_count") var postCount: Int
    @Field(key: "last_activity_at") var lastActivityAt: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    init() {}

    init(slug: String, name: String, description: String, creatorId: UUID, now: Date = Date()) {
        self.slug = slug
        self.name = name
        self.description = description
        self.creatorId = creatorId
        postCount = 0
        lastActivityAt = now
    }
}

/// `last_activity_at` starts at creation and moves with every comment, so the
/// "active" sort never has to coalesce.
final class BoardPost: Model, @unchecked Sendable {
    static let schema = "board_posts"

    @ID(key: .id) var id: UUID?
    @Field(key: "board_id") var boardId: UUID
    @Field(key: "author_id") var authorId: UUID
    @Field(key: "kind") var kind: String
    @Field(key: "title") var title: String
    @OptionalField(key: "url") var url: String?
    @OptionalField(key: "domain") var domain: String?
    @OptionalField(key: "body") var body: String?
    @Field(key: "tags") var tags: [String]
    @Field(key: "score") var score: Int
    @Field(key: "comment_count") var commentCount: Int
    @Field(key: "participant_count") var participantCount: Int
    @Field(key: "view_count") var viewCount: Int
    @Field(key: "last_activity_at") var lastActivityAt: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    init() {}

    init(
        boardId: UUID,
        authorId: UUID,
        kind: String,
        title: String,
        url: String?,
        domain: String?,
        body: String?,
        tags: [String],
        now: Date = Date()
    ) {
        self.boardId = boardId
        self.authorId = authorId
        self.kind = kind
        self.title = title
        self.url = url
        self.domain = domain
        self.body = body
        self.tags = tags
        score = 0
        commentCount = 0
        // The author is the first participant.
        participantCount = 1
        viewCount = 0
        lastActivityAt = now
    }
}

/// Soft-deleted comments stay in the thread as "[deleted]" so their replies
/// keep a parent.
final class BoardCommentRecord: Model, @unchecked Sendable {
    static let schema = "board_comments"

    @ID(key: .id) var id: UUID?
    @Field(key: "post_id") var postId: UUID
    @OptionalField(key: "parent_id") var parentId: UUID?
    @Field(key: "author_id") var authorId: UUID
    @Field(key: "body") var body: String
    @Field(key: "depth") var depth: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt: Date?

    init() {}

    init(postId: UUID, parentId: UUID?, authorId: UUID, body: String, depth: Int) {
        self.postId = postId
        self.parentId = parentId
        self.authorId = authorId
        self.body = body
        self.depth = depth
    }
}

final class BoardVote: Model, @unchecked Sendable {
    static let schema = "board_votes"

    @ID(key: .id) var id: UUID?
    @Field(key: "post_id") var postId: UUID
    @Field(key: "user_id") var userId: UUID
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
}

/// One row per viewer per post: the first insert counts a view, and the stored
/// comment count is what "N new" is measured against on the next visit.
final class BoardPostView: Model, @unchecked Sendable {
    static let schema = "board_post_views"

    @ID(key: .id) var id: UUID?
    @Field(key: "post_id") var postId: UUID
    @Field(key: "user_id") var userId: UUID
    @Field(key: "last_seen_comment_count") var lastSeenCommentCount: Int
    @Field(key: "last_seen_at") var lastSeenAt: Date

    init() {}
}

/// Admin-issued mute or ban. Never deleted: lifting one sets `revoked_at`, so
/// the table doubles as the moderation log.
final class CommunitySanction: Model, @unchecked Sendable {
    static let schema = "community_sanctions"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Field(key: "kind") var kind: String
    @Field(key: "reason") var reason: String
    @OptionalField(key: "expires_at") var expiresAt: Date?
    @OptionalField(key: "created_by") var createdBy: UUID?
    @OptionalField(key: "revoked_at") var revokedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(userId: UUID, kind: String, reason: String, expiresAt: Date?, createdBy: UUID) {
        self.userId = userId
        self.kind = kind
        self.reason = reason
        self.expiresAt = expiresAt
        self.createdBy = createdBy
    }

    func isActive(at now: Date) -> Bool {
        revokedAt == nil && (expiresAt.map { $0 > now } ?? true)
    }
}

/// Acceptance of the community guidelines (App Review Guideline 1.2 asks for
/// agreed terms before anyone can post).
final class CommunityGuidelinesAcceptance: Model, @unchecked Sendable {
    static let schema = "community_guidelines_acceptances"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userId: UUID
    @Timestamp(key: "accepted_at", on: .create) var acceptedAt: Date?

    init() {}

    init(userId: UUID) {
        self.userId = userId
    }
}
