import Fluent
import Foundation
import Vapor

final class ThesisWatchStoryModel: Model, Content, @unchecked Sendable {
    static let schema = "thesis_watch_stories"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "cluster_key")
    var clusterKey: String

    @Field(key: "representative_news_id")
    var representativeNewsId: UUID

    @Field(key: "event_type")
    var eventType: String

    @Field(key: "severity")
    var severity: String

    @Field(key: "first_seen_at")
    var firstSeenAt: Date

    @Field(key: "last_seen_at")
    var lastSeenAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        clusterKey: String,
        representativeNewsId: UUID,
        eventType: String,
        severity: String,
        firstSeenAt: Date,
        lastSeenAt: Date
    ) {
        self.id = id
        self.clusterKey = clusterKey
        self.representativeNewsId = representativeNewsId
        self.eventType = eventType
        self.severity = severity
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }
}
