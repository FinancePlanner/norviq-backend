import Fluent
import Vapor
import Foundation

final class MarketNewsArchive: Model, Content, @unchecked Sendable {
    static let schema = "market_news_archive"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "provider")
    var provider: String

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

    @Field(key: "fetched_at")
    var fetchedAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        provider: String,
        symbol: String,
        headline: String,
        source: String?,
        url: String?,
        summary: String?,
        publishedAt: Date,
        fetchedAt: Date
    ) {
        self.id = id
        self.provider = provider
        self.symbol = symbol
        self.headline = headline
        self.source = source
        self.url = url
        self.summary = summary
        self.publishedAt = publishedAt
        self.fetchedAt = fetchedAt
    }
}
