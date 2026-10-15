import Fluent
import Foundation
import Vapor

/// Whether a user gets one push per market brief, and in which language.
/// No row means off: the brief is opt-in.
final class MarketBriefNotificationPreference: Model, @unchecked Sendable {
    static let schema = "market_brief_notification_preferences"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "enabled")
    var enabled: Bool

    /// `en` or `pt-PT`, the brief the push is written from.
    @Field(key: "language")
    var language: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(userId: UUID, enabled: Bool, language: String) {
        self.userId = userId
        self.enabled = enabled
        self.language = language
    }
}
