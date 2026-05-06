import Fluent
import Foundation
import Vapor

final class EarningsNotificationDelivery: Model, Content, @unchecked Sendable {
    static let schema = "earnings_notification_deliveries"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "symbol")
    var symbol: String

    @Field(key: "earnings_date")
    var earningsDate: String

    @Field(key: "lead_days")
    var leadDays: Int

    @Field(key: "sent_at")
    var sentAt: Date

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        symbol: String,
        earningsDate: String,
        leadDays: Int,
        sentAt: Date = Date()
    ) {
        self.id = id
        self.userId = userId
        self.symbol = symbol
        self.earningsDate = earningsDate
        self.leadDays = leadDays
        self.sentAt = sentAt
    }
}
