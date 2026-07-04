import Fluent
import Foundation
import Vapor

final class SentimentSnapshot: Model, Content, @unchecked Sendable {
    static let schema = "sentiment_snapshots"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "dedupe_key")
    var dedupeKey: String

    @Field(key: "scope")
    var scope: String

    @Field(key: "scope_key")
    var scopeKey: String?

    @Field(key: "window_days")
    var windowDays: Int

    @Field(key: "average_score")
    var averageScore: Double

    @Field(key: "label")
    var label: String

    @Field(key: "event_count")
    var eventCount: Int

    @Field(key: "positive_count")
    var positiveCount: Int

    @Field(key: "neutral_count")
    var neutralCount: Int

    @Field(key: "negative_count")
    var negativeCount: Int

    @Field(key: "captured_at")
    var capturedAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        dedupeKey: String,
        scope: String,
        scopeKey: String?,
        windowDays: Int,
        averageScore: Double,
        label: String,
        eventCount: Int,
        positiveCount: Int,
        neutralCount: Int,
        negativeCount: Int,
        capturedAt: Date
    ) {
        self.id = id
        self.dedupeKey = dedupeKey
        self.scope = scope
        self.scopeKey = scopeKey
        self.windowDays = windowDays
        self.averageScore = averageScore
        self.label = label
        self.eventCount = eventCount
        self.positiveCount = positiveCount
        self.neutralCount = neutralCount
        self.negativeCount = negativeCount
        self.capturedAt = capturedAt
    }
}
