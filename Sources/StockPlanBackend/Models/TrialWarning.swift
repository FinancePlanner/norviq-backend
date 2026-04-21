import Fluent
import Foundation

enum TrialWarningType: String, Codable {
    case expiringSoon = "expiring_soon"
    case expired = "expired"
}

final class TrialWarning: Model, @unchecked Sendable {
    static let schema = "trial_warnings"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "warning_type")
    var warningType: TrialWarningType

    @Field(key: "sent_at")
    var sentAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        userID: UUID,
        warningType: TrialWarningType,
        sentAt: Date = Date()
    ) {
        self.id = id
        self.userID = userID
        self.warningType = warningType
        self.sentAt = sentAt
    }
}
