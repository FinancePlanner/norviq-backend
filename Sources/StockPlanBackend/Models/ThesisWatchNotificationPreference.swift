import Fluent
import Foundation
import Vapor

final class ThesisWatchNotificationPreference: Model, Content, @unchecked Sendable {
    static let schema = "thesis_watch_notification_preferences"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "enabled")
    var enabled: Bool

    @Field(key: "timezone")
    var timezone: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(userId: UUID, enabled: Bool = false, timezone: String = "UTC") {
        self.userId = userId
        self.enabled = enabled
        self.timezone = timezone
    }
}
