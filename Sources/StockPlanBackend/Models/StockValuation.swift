import Fluent
import Foundation
import Vapor

final class StockValuation: Model, Content, @unchecked Sendable {
    static let schema = "stock_valuations"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "symbol")
    var symbol: String

    @Field(key: "bear_low")
    var bearLow: Double

    @Field(key: "bear_high")
    var bearHigh: Double

    @Field(key: "base_low")
    var baseLow: Double

    @Field(key: "base_high")
    var baseHigh: Double

    @Field(key: "bull_low")
    var bullLow: Double

    @Field(key: "bull_high")
    var bullHigh: Double

    @Field(key: "rationale")
    var rationale: String?

    @Field(key: "target_date")
    var targetDate: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        userId: UUID,
        symbol: String,
        bearLow: Double,
        bearHigh: Double,
        baseLow: Double,
        baseHigh: Double,
        bullLow: Double,
        bullHigh: Double,
        rationale: String? = nil,
        targetDate: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.symbol = symbol
        self.bearLow = bearLow
        self.bearHigh = bearHigh
        self.baseLow = baseLow
        self.baseHigh = baseHigh
        self.bullLow = bullLow
        self.bullHigh = bullHigh
        self.rationale = rationale
        self.targetDate = targetDate
    }
}
