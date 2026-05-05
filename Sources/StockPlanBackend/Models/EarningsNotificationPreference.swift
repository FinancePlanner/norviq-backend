import Fluent
import Foundation
import Vapor

final class EarningsNotificationPreference: Model, Content, @unchecked Sendable {
    static let schema = "earnings_notification_preferences"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "enabled")
    var enabled: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, userId: UUID, enabled: Bool) {
        self.id = id
        self.userId = userId
        self.enabled = enabled
    }
}
