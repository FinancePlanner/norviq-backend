import Fluent
import Foundation
import StockPlanShared
import Vapor

final class UserActivity: Model, Content, @unchecked Sendable {
    static let schema = "user_activities"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Enum(key: "type")
    var type: UserActivityType

    @Field(key: "title")
    var title: String

    @Field(key: "subtitle")
    var subtitle: String

    @OptionalField(key: "amount")
    var amount: Double?

    @Field(key: "is_growth")
    var isGrowth: Bool

    @Field(key: "symbol")
    var symbol: String

    @OptionalField(key: "reference_key")
    var referenceKey: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        type: UserActivityType,
        title: String,
        subtitle: String,
        amount: Double? = nil,
        isGrowth: Bool,
        symbol: String,
        referenceKey: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.amount = amount
        self.isGrowth = isGrowth
        self.symbol = symbol
        self.referenceKey = referenceKey
    }
}
