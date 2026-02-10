import Fluent
import Vapor
import Foundation

final class Target: Model, Content, @unchecked Sendable {
    static let schema = "targets"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "symbol")
    var symbol: String

    @Field(key: "scenario")
    var scenario: String

    @Field(key: "target_price")
    var targetPrice: Double

    @Field(key: "target_date")
    var targetDate: Date?

    @Field(key: "rationale")
    var rationale: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        userId: UUID,
        symbol: String,
        scenario: String,
        targetPrice: Double,
        targetDate: Date? = nil,
        rationale: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.symbol = symbol
        self.scenario = scenario
        self.targetPrice = targetPrice
        self.targetDate = targetDate
        self.rationale = rationale
    }
}
