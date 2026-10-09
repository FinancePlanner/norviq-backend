import Fluent
import Foundation

/// A user-published, ticker-tagged write-up. Never hard-deleted: `status`
/// moves to `hidden` (moderator) or `deleted` (author).
final class Article: Model, @unchecked Sendable {
    static let schema = "articles"

    @ID(key: .id) var id: UUID?
    @Field(key: "code") var code: String
    @Field(key: "author_id") var authorId: UUID
    @Field(key: "slug") var slug: String
    @Field(key: "title") var title: String
    @Field(key: "body_markdown") var bodyMarkdown: String
    @Field(key: "bullet_points") var bulletPoints: [String]
    @Field(key: "tickers") var tickers: [String]
    @Field(key: "disclosure") var disclosure: String
    @OptionalField(key: "cover_image_id") var coverImageId: UUID?
    @Field(key: "status") var status: String
    @Field(key: "source") var source: String
    @Field(key: "view_count") var viewCount: Int
    @Field(key: "upvote_count") var upvoteCount: Int
    @Field(key: "word_count") var wordCount: Int
    @Field(key: "published_at") var publishedAt: Date
    @OptionalField(key: "edited_at") var editedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        authorId: UUID, code: String, slug: String, title: String, bodyMarkdown: String,
        bulletPoints: [String], tickers: [String], disclosure: String, coverImageId: UUID?,
        source: String, wordCount: Int, now: Date = Date()
    ) {
        self.authorId = authorId
        self.code = code
        self.slug = slug
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.bulletPoints = bulletPoints
        self.tickers = tickers
        self.disclosure = disclosure
        self.coverImageId = coverImageId
        status = "published"
        self.source = source
        viewCount = 0
        upvoteCount = 0
        self.wordCount = wordCount
        // Whole milliseconds, so the feed cursor (epoch ms) matches exactly.
        publishedAt = Date(timeIntervalSince1970: (now.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
    }
}

final class ArticleVote: Model, @unchecked Sendable {
    static let schema = "article_votes"

    @ID(key: .id) var id: UUID?
    @Field(key: "article_id") var articleId: UUID
    @Field(key: "user_id") var userId: UUID
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
}

/// One row per viewer per UTC day. The first insert of the day counts a view.
final class ArticleView: Model, @unchecked Sendable {
    static let schema = "article_views"

    @ID(key: .id) var id: UUID?
    @Field(key: "article_id") var articleId: UUID
    @Field(key: "viewer_key") var viewerKey: String
    @Field(key: "day") var day: String

    init() {}
}

/// Cover images live in Postgres: Norviq has no object storage, and covers are
/// capped at 2 MB, one per article.
final class ArticleImage: Model, @unchecked Sendable {
    static let schema = "article_images"

    @ID(key: .id) var id: UUID?
    @Field(key: "owner_id") var ownerId: UUID
    @Field(key: "content_type") var contentType: String
    @Field(key: "bytes") var bytes: Data
    @Field(key: "width") var width: Int
    @Field(key: "height") var height: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(ownerId: UUID, image: SniffedImage, bytes: Data) {
        self.ownerId = ownerId
        contentType = image.contentType
        self.bytes = bytes
        width = image.width
        height = image.height
    }
}
