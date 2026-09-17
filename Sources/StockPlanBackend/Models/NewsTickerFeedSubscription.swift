import Fluent
import Foundation
import Vapor

/// A feed a user added to their own ticker. Private to that user; the shared
/// aggregator only ever sees the URL, never who asked for it.
final class NewsTickerFeedSubscription: Model, Content, @unchecked Sendable {
    static let schema = "news_ticker_feed_subscriptions"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "feed_url")
    var feedUrl: String

    @OptionalField(key: "title")
    var title: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, userId: UUID, feedUrl: String, title: String?) {
        self.id = id
        self.userId = userId
        self.feedUrl = feedUrl
        self.title = title
    }
}
