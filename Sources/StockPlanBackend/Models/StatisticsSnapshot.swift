import Fluent
import Vapor
import Foundation

final class StatisticsSnapshot: Model, Content, @unchecked Sendable {
    static let schema = "statistics_snapshots"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userId: UUID

    @Field(key: "as_of_date")
    var asOfDate: Date

    @Field(key: "generated_at")
    var generatedAt: Date

    @Field(key: "total_market_value")
    var totalMarketValue: Double

    @Field(key: "total_cost_basis")
    var totalCostBasis: Double

    @Field(key: "total_unrealized_pnl")
    var totalUnrealizedPnl: Double

    @Field(key: "total_realized_pnl")
    var totalRealizedPnl: Double

    @Field(key: "payload")
    var payload: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() { }

    init(
        id: UUID? = nil,
        userId: UUID,
        asOfDate: Date,
        generatedAt: Date,
        totalMarketValue: Double,
        totalCostBasis: Double,
        totalUnrealizedPnl: Double,
        totalRealizedPnl: Double,
        payload: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.asOfDate = asOfDate
        self.generatedAt = generatedAt
        self.totalMarketValue = totalMarketValue
        self.totalCostBasis = totalCostBasis
        self.totalUnrealizedPnl = totalUnrealizedPnl
        self.totalRealizedPnl = totalRealizedPnl
        self.payload = payload
    }
}
