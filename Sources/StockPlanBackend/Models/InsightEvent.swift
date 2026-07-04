import Fluent
import Foundation
import Vapor

final class InsightEvent: Model, Content, @unchecked Sendable {
    static let schema = "insight_events"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "dedupe_key")
    var dedupeKey: String

    @Field(key: "source")
    var source: String

    @Field(key: "topic")
    var topic: String

    @Field(key: "title")
    var title: String?

    @Field(key: "summary")
    var summary: String?

    @Field(key: "sentiment_label")
    var sentimentLabel: String?

    @Field(key: "sentiment_score")
    var sentimentScore: Double?

    @Field(key: "source_url")
    var sourceURL: String?

    @Field(key: "author")
    var author: String?

    @Field(key: "observed_at")
    var observedAt: Date

    @Field(key: "raw_payload")
    var rawPayload: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        dedupeKey: String,
        source: String,
        topic: String,
        title: String?,
        summary: String?,
        sentimentLabel: String?,
        sentimentScore: Double?,
        sourceURL: String?,
        author: String?,
        observedAt: Date,
        rawPayload: String?
    ) {
        self.id = id
        self.dedupeKey = dedupeKey
        self.source = source
        self.topic = topic
        self.title = title
        self.summary = summary
        self.sentimentLabel = sentimentLabel
        self.sentimentScore = sentimentScore
        self.sourceURL = sourceURL
        self.author = author
        self.observedAt = observedAt
        self.rawPayload = rawPayload
    }
}
