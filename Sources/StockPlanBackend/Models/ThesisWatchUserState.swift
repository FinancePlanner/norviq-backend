import Fluent
import Foundation
import Vapor

final class ThesisWatchUserState: Model, Content, @unchecked Sendable {
    static let schema = "thesis_watch_user_states"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "story_id")
    var storyId: UUID

    @OptionalField(key: "symbol")
    var symbol: String?

    @Field(key: "impact")
    var impact: String

    @OptionalField(key: "confidence")
    var confidence: Double?

    @OptionalField(key: "summary")
    var summary: String?

    @OptionalField(key: "why_it_matters")
    var whyItMatters: String?

    @OptionalField(key: "feedback")
    var feedback: String?

    @OptionalField(key: "read_at")
    var readAt: Date?

    @OptionalField(key: "dismissed_at")
    var dismissedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(userId: UUID, storyId: UUID, impact: String = "not_assessed") {
        self.userId = userId
        self.storyId = storyId
        self.impact = impact
    }
}
