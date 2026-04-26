import Fluent
import Foundation
import Vapor

final class NewsItem: Model, Content, @unchecked Sendable {
    static let schema = "news_items"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "symbol")
    var symbol: String

    @Field(key: "headline")
    var headline: String

    @Field(key: "source")
    var source: String?

    @Field(key: "url")
    var url: String?

    @Field(key: "summary")
    var summary: String?

    @Field(key: "published_at")
    var publishedAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        symbol: String,
        headline: String,
        source: String?,
        url: String?,
        summary: String?,
        publishedAt: Date
    ) {
        self.id = id
        self.userId = userId
        self.symbol = symbol
        self.headline = headline
        self.source = source
        self.url = url
        self.summary = summary
        self.publishedAt = publishedAt
    }
}
